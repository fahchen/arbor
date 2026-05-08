# Backlog

## Deferred Features

Awaiting their own discovery sessions.

- **replication/json-patch-diff** — RFC 6902 diff engine, patch envelope shape, version numbering, resync path, stream-op packing. (Surfaced 2026-05-08 during runtime/command-routing.)
- **streams/lifecycle** — LiveView-parity stream API (`stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_dom_id/3`), `:at`/`:limit`/`:reset`/`:dom_id`/`:update_only`, `reload_stream/2` callback. (Surfaced 2026-05-08 during runtime/command-routing; render-contract confirms stream-typed `field` markers handled separately.)
- **async/lifecycle** — `assign_async/3,4`, `start_async/3,4`, `cancel_async/2,3`, `handle_async/3`, `Arbor.AsyncResult`, `:timeout`, `:reset` (including subset-list form), automatic cancellation on child node disappearance via supervisor link, `Task.Supervisor`. (Surfaced 2026-05-08 during runtime/command-routing.)
- **async/stream-async** — `stream_async/4` (LV parity): async task whose result re-seeds a stream. (Surfaced 2026-05-08 during runtime/command-routing.)
- **persistence/snapshot-roundtrip** — Snapshot adapter behaviour, `assigns` + dom_id index serialization, reconcile-on-restore, `persist: :ok_only` async opt-in. (Surfaced 2026-05-08 during runtime/command-routing.)

## Open Decisions

(None at present.)
