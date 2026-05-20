# Backlog

## Deferred Features

### Uploads v2

- **`:writer` custom write target** — channel-mode uploads currently write to a
  `Plug.Upload.random_file!/1` temp file. A future option would let store
  authors hand in a `{module, opts}` writer (e.g. stream directly into S3
  multipart upload while bytes arrive). Deferred per BDR-0026 to keep v1 small.
- **`:auto_upload` sugar** — today clients call `select(files)` then `start()`
  explicitly. An `auto_upload: true` switch could fire `start` immediately
  after a successful preflight. Defer until the explicit API has soaked.
- **Resumable uploads** — reconnect currently discards in-flight chunk state
  (consistent with BDR-0003 let-it-crash). A range-resume protocol would
  re-issue tokens carrying `bytes_written` so the client can pick up where it
  left off.
- **Headless dropzone / image preview helpers** — application owns UI. If a
  set of patterns emerges across consumers we may ship a thin headless
  component package.
- **Directory uploads** — `client_relative_path` is not exposed today. Add
  when there is a concrete consumer.
- **Server-side post-upload verification helpers** (HEAD on the object,
  signature check for external mode) — currently the application command
  that consumes the entry runs whatever check it needs.
- **`avatar_upload` example app** — the shipped uploads v1 is documented via
  `guides/uploads.md`. A full Phoenix example mirroring `cart_page`
  (mix project + UI + integration test) lands when the upload UX has
  stabilized through one real consumer.

## Excluded From BDD Scope

- **persistence/snapshot-roundtrip** — Surfaced and explored 2026-05-09. Decision: persistence is **not** a Musubi primitive. Applications implement snapshot save/load via the existing hook (`attach_hook(socket, :persist, :after_command, fn)`) and extension points. Musubi exposes no `Musubi.Persistence` behaviour, no bundled ETS/Postgres adapters, no `persist_now/1` helper, no `persist: :ok_only` opt-in. The pattern may be packaged as a separate companion library (`Musubi.Persistence`) outside the core runtime. Documentation of recommended hook usage lives in `docs/persistence-pattern.md` (TBD).

## Open Decisions

(None at present.)
