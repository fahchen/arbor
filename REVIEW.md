# Codex Review — feat-file-uploads

## Summary
The branch is not merge-ready. The highest-risk problems are that child-store uploads do not work through the real `ConnectionChannel`, channel-mode uploads can be marked successful by forged `upload_progress` events without sending bytes, and the channel-mode temp-file lifecycle is broken enough that successful uploads expose no consumable path and leak files. Current test status: `mix test` fails with 4 failures in `test/musubi/upload/child_store_test.exs`; `pnpm -w test` passes, although `packages/react` prints expected jsdom error-boundary noise while still finishing green.

## Blocking findings
1. `lib/musubi/transport/connection_channel.ex:353` — blocker — `allow_upload`/`cancel_upload`/`upload_progress` resolve upload names only against the root store module, so uploads declared on child stores are rejected on the real transport even though BDR-0028 requires child-store uploads to be the canonical dynamic pattern. Fix: resolve the upload against the addressed `store_id` via the page server/store table, not `fetch_root_entry/2`. Ref: BDR-0028 § 36-40, `spec/domains/uploads/features/lifecycle.feature` "Child store carries the upload".
2. `lib/musubi/page/server.ex:1052` — blocker — the main channel accepts `upload_progress` for any tracked entry and never checks `entry.mode == :external`, which lets a client preflight a channel-mode upload and then forge `progress: 100` without joining the upload sub-channel or sending bytes. Fix: reject `upload_progress` unless the addressed entry exists and is in external mode. Ref: BDR-0027 § 80-83, `docs/uploads.md` "upload_progress (external mode only)".
3. `lib/musubi/transport/upload_channel.ex:127` — blocker — the implementation requires an undocumented `"close"` event to avoid treating a finished upload as a cancel, but the spec defines only binary `"chunk"` frames and says completion happens on the final chunk. A spec-compliant client that stops after the last chunk will hit `terminate/2`, remove the temp file, and emit `cancel`. Fix: make final-chunk completion self-contained on `"chunk"` and remove the protocol dependency on `"close"`. Ref: BDR-0026 § 24-31, `docs/uploads.md` "Per-entry sub-channel (channel mode)", `docs/uploads.md` "End-to-end flow" steps 6-9.
4. `lib/musubi/upload.ex:359` — blocker — `consume_uploaded_entries/3` expects channel-mode entries to carry `%{path: path}`, but no code ever copies the temp-file path from `UploadChannel` into `Musubi.Upload.Entry.path`; successful channel uploads therefore surface `%{path: nil}` and leave the temp file orphaned. Fix: persist the opened temp-file path onto the entry when the sub-channel joins and clear/remove it deterministically after consume/cancel. Ref: `docs/uploads.md` "Helpers (Store facade)", `spec/domains/uploads/features/transport.feature` "Server writes chunk to the temp file".
5. `lib/musubi/transport/upload_channel.ex:86` — blocker — `chunk_timeout` is declared, documented, and carried in config, but the channel never arms or enforces any per-entry timeout between chunks. Fix: track/reset a timer per joined entry and emit scrubbed `chunk_timeout` failure state when it fires. Ref: `docs/uploads.md` options table, `lib/musubi/upload/error.ex`, BDR-0026 § 54-57.
6. `lib/musubi/upload/preflight.ex:193` — blocker — if a store module exports `upload_external/3`, `uses_external?/2` returns `true` for every upload name on that module, so mixed channel/external declarations cannot work and unmatched names do not fall back to channel mode. Fix: make external-mode selection name-specific instead of the current unconditional `function_uses_external_for_name?/2`. Ref: `docs/uploads.md` "When `upload_external/3` is not defined for an upload name the transport falls back", BDR-0027 § 39-41.
7. `lib/musubi/upload/preflight.ex:156` — blocker — `upload_external/3` returns `{:ok, meta, socket}`, but the returned socket is discarded, so any state mutation the callback performs during preflight is lost. Fix: thread the callback’s returned socket back into `Preflight.run/6` and store it in the page server state. Ref: `docs/uploads.md` callback signature, BDR-0027 § 34-41.
8. `lib/musubi/codegen/type_script.ex:197` — blocker — TypeScript codegen still renders store shapes from state fields only; declared uploads never appear in the generated `StoreDef` shape, so the advertised `page.<name>: UploadHandle` surface is absent from generated types. Fix: merge reflected uploads into the generated shape and emit `UploadHandle` properties alongside state fields. Ref: `docs/uploads.md` "Page handle exposure", review priority 5.

## Non-blocking findings
1. `lib/musubi/transport/upload_channel.ex:119` — major — the `"chunk"` reply computes `progress` against `max_file_size` and includes `bytes_written`, so the reply shape is off-spec and progress is wrong for any file smaller than the configured maximum. Fix: reply with `%{progress: integer}` based on the entry’s client size (or drop the reply dependency entirely if the client does not consume it). Ref: `docs/uploads.md` "Per-entry sub-channel (channel mode)".
2. `lib/musubi/transport/upload_channel.ex:93` — major — oversize/chunk-limit validation stops the channel after enqueueing an error, and `terminate/2` then calls `cancel_upload`, so clients will see `error` immediately followed by `cancel` and lose the errored entry state. Fix: distinguish terminal error exits from user/disconnect cancels in `terminate/2`. Ref: BDR-0025 § 53-60, `spec/domains/uploads/features/wire-protocol.feature` "per-entry validation failure".
3. `lib/musubi/transport/upload_channel.ex:103` — major — `IO.binwrite/2` is not wrapped, so disk-write failures crash the channel instead of producing the required scrubbed `{op:"error"}` payload. Fix: catch write failures, emit `Musubi.Upload.Error.new(:internal)` (or a dedicated code), and avoid leaking runtime details through crash paths. Ref: `spec/domains/uploads/features/wire-protocol.feature` "Disk write failure".
4. `packages/client/src/types.ts:334` — minor — `PatchEnvelope.upload_ops` is typed as optional even though the wire contract now requires it on every envelope. Fix: make `upload_ops` required in the TS type. Ref: BDR-0025 § 40-50.

## Spec gaps or inconsistencies
1. `spec/decisions/BDR-0027-uploads-external-mode-v1.md:11` references `domains/uploads/features/external.feature`, but the branch only adds `lifecycle.feature`, `transport.feature`, and `wire-protocol.feature`. The external-mode behavior therefore has no matching feature file.
2. `spec/decisions/BDR-0026-upload-sub-channel-and-stateless-token.md:43` shows a token payload without `store_id`, while `docs/uploads.md`, the implementation, and the child-store design all require `store_id` in the token to route ops back to child stores.
3. The review priorities and `docs/uploads.md` say `accept` enforcement lives in `UploadChannel` and is sourced from the verified token payload, but the token payload contains no client filename or MIME type, and the BDD scenarios only exercise `accept` at preflight time. The spec should explicitly choose preflight-only validation or expand the token/join payload so channel-side enforcement is actually possible.

## Test gaps
1. No ExUnit test actually joins `Musubi.Transport.UploadChannel`, pushes raw binary `"chunk"` frames, and asserts join verification, reply shape, temp-file creation, or cleanup. `test/musubi/upload/transport_test.exs` is preflight-only.
2. No test covers the documented `chunk_timeout` behavior, which is why the missing timeout enforcement ships unnoticed.
3. No test exercises the real `ConnectionChannel` path for child-store uploads. The current child-store coverage bypasses transport via `Musubi.Testing.allow_upload/5`, so it misses the root-only upload lookup bug in `resolve_upload_name/3`.
4. No test asserts that `consume_uploaded_entries/3` receives a non-nil `%{path: ...}` for channel-mode entries or that postponed channel entries retain a valid temp file across a second consume.
5. No TS/codegen test asserts that generated store types include upload handles or reject upload/state name collisions at the generated type surface.
6. No transport or client test covers external uploader failure (`external_failed`), missing uploader registration, or cancellation of an in-flight external upload.
7. `mix test` is currently red because all 4 tests in `test/musubi/upload/child_store_test.exs` fail before asserting upload behavior; the fixture declares `field :lines, list(CartLineStore.state())`, but the runtime validates the rendered list against `%{"line_id" => ...}` wire maps and aborts mount first.

## Verified-OK
- `lib/musubi/upload/token.ex` centralizes the upload-token salt and `max_age` at `600`, and `UploadChannel.join/3` verifies through that single path.
- `lib/musubi/upload/entry.ex` derives a wire whitelist that excludes `path`, `token`, `store_pid`, `upload_channel_pid`, `bytes_written`, `external_meta`, and `preflighted_at`.
- `lib/musubi/page/patch_envelope.ex` serializes `upload_ops` alongside `ops` and `stream_ops`, and `PatchEnvelope.build/4` emits an envelope when `upload_ops` is the only non-empty op track.
- `packages/client/src/uploads.ts` keeps one stable `UploadHandleImpl` instance per `{store_id, upload}` key and mutates it in place as `upload_ops` arrive.

---

## Addendum — Resolution of review findings

Branch is now merge-ready. `mix test` → 12 doctests, 412 tests, 0 failures.
`pnpm -w test` → client 48/48, react 30/30. `mix format --check-formatted`
clean.

### Blocking findings — resolved

| # | Description | Commit |
| :-- | :-- | :-- |
| 1 | child-store upload resolution by `store_id` | `115860d` |
| 2 | refuse `upload_progress` for channel-mode entries | `115860d` |
| 3 | self-contained completion on final `"chunk"`, no `"close"` | `971b847` |
| 4 | persist temp-file path on the entry; consume hands real `%{path: path}` | `971b847` |
| 5 | `chunk_timeout` watchdog arms / resets / fires | `971b847` |
| 6 | per-name external selection via callback dispatch (`:channel` / `FunctionClauseError`) | `6a5eb29` |
| 7 | thread socket returned by `upload_external/3` back through preflight | `6a5eb29` |
| 8 | TS codegen emits `UploadHandle`-typed fields per declared upload | `5ca99a5` |

### Non-blocking findings — resolved

| # | Description | Commit |
| :-- | :-- | :-- |
| 1 | reply progress 0..100 against `client_size`; reply shape `%{progress: integer}` | `971b847` |
| 2 | `terminate/2` distinguishes succeeded / errored / cancel; no double-emit | `971b847` |
| 3 | `IO.binwrite/2` wrapped; disk-write failure emits scrubbed `:internal` | `971b847` |
| 4 | `PatchEnvelope.upload_ops` typed as required | `5ca99a5` |

### Spec gaps — closed

| # | Description | Commit |
| :-- | :-- | :-- |
| 1 | `spec/domains/uploads/features/external.feature` added | `4a77fa5` |
| 2 | BDR-0026 + `docs/uploads.md` token payload list `store_id`, `client_size`, `chunk_timeout` | `4a77fa5` |
| 3 | accept enforcement scope = preflight-only, documented in BDR-0026 + docs | `4a77fa5` |

### Test gaps — closed

| # | Description | Commit |
| :-- | :-- | :-- |
| 1 | real `UploadChannel` join test (binary chunks, reply shape, temp-file lifecycle, dead-pid / forged / unknown-topic rejection) | `5917bd2` |
| 2 | `chunk_timeout` watchdog test | `5917bd2` |
| 3 | `ConnectionChannel` child-store transport test (`upload_connection_test.exs`) | `5917bd2` |
| 4 | `consume_uploaded_entries/3` real `%{path: path}` + postpone retention | `5917bd2` |
| 5 | TS codegen test: upload handles emitted; collision rejected | `5917bd2` |
| 6 | external-mode: cancel of in-flight, per-name fallback, socket persistence | `5917bd2` |
| 7 | `mix test` red `child_store_test.exs` | already resolved in `8cdede9` (pre-review fix) — no fixture reshape needed because the existing commit already moved to `list(CartLineStore.state())` |

### Deferred items

None. All findings were addressed in-tree. Future hardening lives in
`spec/backlog.md` under the existing "Uploads v2" section (no changes).
