# Backlog

## Deferred Features

Surfaced during `runtime/command-routing` discovery on 2026-05-08; out of scope for that feature, awaiting their own discovery sessions.

- **runtime/render-contract** — `child(...)` placeholder resolution, render-output validation, identity preservation across reorders, mount/update/unmount lifecycle.
- **replication/json-patch-diff** — RFC 6902 diff engine, patch envelope shape, version numbering, resync path, stream-op packing.
- **streams/lifecycle** — LiveView-parity stream API (`stream/4`, `stream_configure/3`, `stream_insert/4`, `stream_delete/3`, `stream_delete_by_dom_id/3`), `:at`/`:limit`/`:reset`/`:dom_id`/`:update_only`, `reload_stream/2` callback.
- **async/lifecycle** — `assign_async/3,4`, `start_async/3,4`, `cancel_async/2,3`, `handle_async/3`, `Arbor.AsyncResult`, `:timeout`, `:reset` (including subset-list form), automatic unmount-cancel, `Task.Supervisor`.
- **async/stream-async** — `stream_async/4` (LV parity): async task whose result re-seeds a stream.
- **persistence/snapshot-roundtrip** — Snapshot adapter behaviour, `assigns` + dom_id index serialization, reconcile-on-restore, `persist: :ok_only` async opt-in.

## Open Decisions

(None at present.)
