---
id: BDR-0015
title: No application-level resync command; loss recovery is the reconnect path
status: accepted
date: 2026-05-08
summary: Drop arbor:request_resync (and any subtree-resync variants). Under 1:1 transport binding (BDR-0003), version gaps cannot occur mid-session; client recovery is the standard reconnect → fresh mount → first patch carrying full root.
---

## Scope

**Feature**: domains/replication/features/json-patch-diff.feature
**Rule**: There is no application-level resync command; reconnect is the recovery path

## Reason

Earlier discovery drafts proposed an `arbor:request_resync` system command that the client would send when it detected a version gap, prompting the server to emit a `replace` patch reseating subtree or root. Examined against the rest of the design:

- **BDR-0003** binds the page runtime 1:1 to the transport. Disconnect kills the runtime; reconnect mounts a fresh runtime and re-runs `mount/3`.
- **Phoenix Channel** preserves order over a single channel — there is no transport-level scenario where the client falls behind on patch versions while the channel remains open.
- **One render cycle = one envelope** (Rule 11) and the runtime emits envelopes synchronously to the transport — there is no buffering layer that could drop intermediate patches.

Together these mean a mid-session version gap simply cannot arise under the current model. Adding a resync command surfaces wire complexity, a server-side handler, and a client-side gap-detection loop with no triggering scenario. Loss recovery is identical to first connect: client tears down the transport, reconnects, gets a fresh mount, and the first patch envelope (`base_version: 0, version: 1, ops: [{replace path "" value root}]`) restores known-good state.

Stream-content recovery (a real concern, since the server forgets stream item values) is handled separately: the application calls `stream(socket, name, fresh_items, reset: true)` directly (or `stream_async(reset: true)` for an async re-fetch) within the standard envelope flow, not via a resync command (BDR-0022).
