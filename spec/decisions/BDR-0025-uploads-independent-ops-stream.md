---
id: BDR-0025
title: Upload state ships in an independent `upload_ops` stream, not in JSON Patch diff
status: accepted
date: 2026-05-19
summary: Per-entry upload state (config, add, progress, complete, error, cancel, reset) is delivered through a third op array on the envelope (`upload_ops`), parallel to `stream_ops`. JSON Patch `ops` carries only the static marker at the declaration path. Progress updates do not mark `socket.assigns` as changed and never trigger main-store re-renders.
---

## Scope

**Feature**: domains/uploads/features/wire-protocol.feature
**Rule**: Upload mutation flows through `upload_ops`, not through diffed state

## Reason

Progress is high-frequency. A 5 MB file at the default 64 KB chunk size
produces 80 progress updates per entry; with `max_entries: 10` running
in parallel, the system must absorb hundreds of progress events per
second per page. Routing those through JSON Patch diffing pollutes the
change-tracking layer:

- Each progress update marks the upload's assigns slot dirty.
- The render pipeline reruns the store's `render/1`.
- The diff engine compares the new wire tree against the previous one
  and emits a `{op: "replace", path: "/avatar/entries/0/progress", value: N}`
  op.

This wastes work on a value the application never reads from
`socket.assigns` and never composes into render output. It also makes
coalescing — collapsing consecutive progress updates within one drain
cycle — awkward, because the diff engine cannot see that "more progress
is on the way" or which prior ops can be discarded.

Streams faced the same fundamental problem (high-frequency mutation of
a wire-shaped collection) and solved it with the existing `stream_ops`
side channel: the wire tree carries a stable marker; per-item changes
flow through a separate op array; render does not need to rerun for an
op-only emission (BDR-0018). Uploads adopt the same pattern.

The wire envelope grows a third op array:

```json
{
  "type": "patch",
  "base_version": 5,
  "version": 6,
  "ops": [...],
  "stream_ops": [...],
  "upload_ops": [...]
}
```

with the op vocabulary `config / add / progress / complete / error /
cancel / reset`. Each op carries a `store_id` matching the path of the
store that owns the upload. Upload mutation queues into
`socket.assigns.__uploads__.__pending_ops__` and is drained at the same
point in the cycle as `stream_ops`. During drain, consecutive
`progress` ops sharing `{store_id, upload, ref}` collapse to the latest
value, and a 10 Hz default throttle caps emission. Upload mutation
never marks other assigns dirty: the main store does not re-render
because a chunk arrived.

The framework rule "an envelope is emitted when ops OR stream_ops is
non-empty" (BDR-0018) extends to `upload_ops`: a cycle with non-empty
`upload_ops` emits an envelope even when `ops` and `stream_ops` are
empty.
