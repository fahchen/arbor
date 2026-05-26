# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Elixir package (`musubi`) and the JS packages (`@musubi/client`,
`@musubi/react`) share this changelog. Per-package version numbers are
not in lockstep yet; entries note which surface they affect.

## [Unreleased]

## [0.4.0] — 2026-05-26

### Changed

- Command replies now serialize through `Musubi.Wire` (#57). Replies match
  the wire shape the client receives (string keys, stringified atoms), and
  schema validation runs against that form — fixing atom-valued and nested
  reply-field validation. `:after_command` hooks and `[:musubi, :auth,
  :deny]` telemetry still see the raw reply (atom keys/values).

### Added

- `Musubi.Wire` support for `DateTime`/`NaiveDateTime`/`Date`/`Time`
  (ISO8601) and `URI` (string) (#57). `MapSet`, `Decimal`, and tuples stay
  unhandled and raise `Protocol.UndefinedError` — convert first.

## [0.3.0] — 2026-05-20

### Added

- **File uploads** (#54). Top-level `upload :name, opts` DSL declared
  per store, outside `state do`. The framework auto-injects
  `{"__musubi_upload__": "<name>"}` markers into render output. Upload
  state ships through an independent `upload_ops` envelope stream
  (`config / add / progress / complete / error / cancel / reset`),
  parallel to `stream_ops`; progress mutation does not pollute
  `__changed__` or trigger `render/1`. Authorization uses a per-entry
  `musubi_upload:<entry_ref>` sub-channel joined with a `Phoenix.Token`
  (HMAC, `max_age: 600`). External (S3/R2 direct) mode ships in v1
  via the optional `upload_external/3` callback. Store facade:
  `consume_uploaded_entries/3`, `cancel_upload/3`,
  `uploaded_entries/2`. New optional callback: `handle_progress/3`.
  Client surface exposes `page.<name>` as a stable reactive
  `UploadHandle` with TanStack-style `status` enum and `isXxx`
  mirrors; no separate React hook. Full reference in
  `docs/uploads.md`; design decisions in
  `spec/decisions/BDR-0024..0028`.

### Changed

- **BREAKING (DSL)** — `command :name, ...` is replaced by the
  block-form `command :name do ... end`, with explicit `payload do
  ... end` and `reply do ... end` sub-blocks for schema declaration.
  Reply validation is now mandatory when a `reply do` block is
  declared. Migration: rewrite each `command :name, payload: ...,
  reply: ...` call as the block form (#53).
- README documents how to wire a Phoenix endpoint socket for Musubi
  (#52).

### Fixed

- `cart_page` example: declare command reply types so the example
  compiles under the strict reply validation (#51).

## [0.2.0] — 2026-05-18

### Added

- `Musubi.Testing` test harness — `mount/3`, `dispatch_command/4`,
  `render/2`, and the `assigns/2` escape hatch for asserting on store
  state from ExUnit.
- `createMusubi` client factory — bind a store type once and reuse the
  resulting page/command/subscribe API across an application.
- React Suspense integration and an `<MusubiProvider>` that accepts a
  raw `Phoenix.Socket` directly.
- Structured command errors. `useMusubiCommand` now returns a
  mutation-shaped value (`mutate`, `isPending`, `data`, `error`, …).
- Phoenix matrix in CI; publish workflow; MIT LICENSE and README
  badges.

### Changed

- **BREAKING (rename)** — Package renamed from `Arbor` to `Musubi`
  throughout the codebase, docs, and configuration.
- `Arbor.Store` facade reshaped to mirror LiveView's call surface,
  including `assign_new/3` and `update/3`.

### Performance

- Resolver short-circuits `render/1` when the root socket is
  unchanged; cached child `wire_state` stitches into the parent wire
  output without re-walk.
- Reconciler checks parent assign value equality before computing
  changed-key intersections; deep-tree leaf dirty detection is
  prune-safe.
- Page server skips `Jsonpatch` diffing when the wire root is
  structurally equal between cycles.
- Client invalidates `snapshotCache` by op path instead of clearing
  the entire cache.

### Fixed

- Reconciler deep-tree leaf dirty detection now survives prune cycles
  without losing references.

## [0.1.0] — 2026-05-17

Initial public release of the Musubi runtime (then `Arbor`):

- Server-authoritative, page-scoped runtime over `Phoenix.Channel`.
- Stores declared via `use Musubi.Store` with `state do … end`,
  command handlers, async helpers, and a `render/1` callback.
- Per-page diff pipeline emitting RFC 6902 JSON Patch envelopes.
- LV-aligned change tracking via per-key `__changed__` flags.
- Streams with stable wire markers and an independent `stream_ops`
  delta channel; LiveView-aligned semantics.
- Async helpers: `assign_async/3,4`, `start_async/3,4`,
  `cancel_async/2,3`, `stream_async/3,4`.
- TypeScript client and React adapter that materialize the diff stream
  into immutable snapshots.

[Unreleased]: https://github.com/fahchen/musubi/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/fahchen/musubi/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/fahchen/musubi/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/fahchen/musubi/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fahchen/musubi/releases/tag/v0.1.0
