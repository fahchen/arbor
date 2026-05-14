---
id: BDR-0018
title: Render cycles with non-empty stream_ops emit envelopes even when JSON Patch ops are empty
status: accepted
date: 2026-05-08
summary: Refines replication/json-patch-diff Rule 1/2. An envelope is emitted whenever ops OR stream_ops is non-empty; otherwise the cycle produces no wire output.
---

## Scope

**Feature**: domains/streams/features/lifecycle.feature
**Rule**: Stream-only render cycles still emit envelopes

## Reason

Replication's original rule said "emit when resolved root output differs". Stream-typed fields are stable marker objects in the wire tree (`{"__arbor_stream__": "<name>"}`), so a handler that *only* mutates a stream produces no JSON Patch ops yet still has stream-content changes the client must see. Without this refinement, those changes would be silently dropped: the runtime would compute zero `ops`, decline to emit an envelope, and the client would never receive the queued `stream_ops`. The rule is therefore expanded to "ops OR stream_ops non-empty" — both arrays gate emission. The all-empty case continues to emit nothing.
