---
id: BDR-0024
title: Uploads declared at the top level; framework injects wire markers automatically
status: accepted
date: 2026-05-19
summary: Uploads are not state. `upload :name, opts` is declared at the top level of a store module, outside `state do`. Render code does not place the marker — the framework injects `{"__musubi_upload__": "<name>"}` into the wire output after `render/1` returns. Application code never composes upload state by hand.
---

## Scope

**Feature**: domains/uploads/features/lifecycle.feature
**Rule**: Uploads are a transport-layer capability, declared separately from state, with framework-injected markers

## Reason

Uploads were initially modeled after streams: a `state do upload :name`
slot declared alongside other state fields, with a render-time builder
(`upload(:name)`) placing the marker. The model collapsed on three
points:

1. **Conceptual mismatch.** Streams are server-owned data (a collection
   whose materialization lives on the client). Uploads are
   transport-layer artefacts: short-lived temp files and an async chunk
   protocol, with the lifecycle owned by the client. LiveView itself
   keeps uploads outside the state struct (`socket.assigns.uploads` is a
   transport detail, not user state). Sharing the `state do` block with
   real data forced the metaphor.

2. **Dynamic containers were impossible.** Streams and lists carry many
   items, but `upload :name` produces a single named slot at a fixed
   path. Stating "put an upload inside a stream item" had no compilable
   meaning. By moving uploads to the top level we make the singleton
   nature explicit, and per-item uploads are expressed via child stores
   (each child declares its own upload — `store_id` on each op
   distinguishes them).

3. **Render placement was pure ceremony.** The user had no decision to
   make at the placement site: every declared upload must show up, and
   only at the declaration path. Forcing `upload(:name)` in render
   created an opportunity for omission/error without buying any
   expressiveness.

The current rule:

- `upload :name, opts` lives at the top level of a store module.
- `render/1` does not write upload markers.
- After `render/1` returns, the framework auto-injects
  `{"__musubi_upload__": "<name>"}` at the root of the store's render
  output for each declared upload — identical structure to streams'
  `{"__musubi_stream__": "<name>"}`.
- Application code that hand-writes an upload marker is rejected at
  render-validation time, mirroring stream marker enforcement.

The client surface stays flat — `page.<name>` resolves the marker to a
stable `UploadHandle`. To keep the namespace unambiguous, compile-time
validation rejects an `upload :name` whose name collides with any state
field in the same store.
