---
id: BDR-0016
title: Stream-typed fields are server-forgets-values, client-owns-materialization
status: accepted
date: 2026-05-08
summary: After a stream op is flushed to the wire, the server retains only the ordered dom_id index — never the item values. The client materializes the full list locally and is the source of truth for displayed contents.
---

**Feature**: streams/features/lifecycle.feature
**Rule**: After flush the runtime forgets stream values; only the dom_id index is retained

## Context

Long, append-mostly collections (chat history, activity feeds, log streams) do not fit the "server holds full state" model: a 50K-item chat would otherwise tie up server memory linearly. `Phoenix.LiveView`'s `stream/4` family solves this by emitting per-op deltas to the client and dropping item values server-side after each render flush. Arbor adopts the model directly because:

- The wire payload model already separates JSON Patch (full state) from stream ops (deltas).
- Persistence is an application-driven pattern (via hooks; see `spec/backlog.md`); applications that want to persist the dom_id index for `:limit` accounting on restart can do so without retaining item values.
- Reconnect re-seeding via `mount/1` or `reload_stream/2` covers the "server lost state" recovery path.

## Behaviours Considered

### Option A: Server forgets values; client owns materialization

After flush, server retains only ordered dom_ids. Reload requires application data source. Memory bound regardless of stream size.

### Option B: Server retains items in addition to dom_ids

Hold the full collection in `assigns`. Allows server-side queries on stream contents. Memory grows linearly with stream size; persistence load grows similarly.

### Option C: Hybrid — bounded retention server-side (e.g., last N items)

Cap server-side retention at `:limit` items even when client materializes more. Adds bounding logic and a non-deterministic divergence between server view and client view.

## Decision

Adopt Option A. Server forgets item values immediately after flush. Server retains only the ordered dom_id index for `:limit` enforcement, dedup-on-upsert detection, and reload accounting.

## Rejected Alternatives

Option B was rejected because:
- It defeats the bandwidth purpose of streams: if the server holds it, JSON Patch could just diff the array.
- Memory grows proportional to all open pages × stream sizes per page; unbounded under load.
- It ties stream lifecycle to GC pressure on the runtime.

Option C was rejected because:
- It fragments the model: server has a partial view, client has a different view. Reasoning about "current state" requires picking which side.
- `:limit` semantics are already client-visible; piggybacking server retention on `:limit` conflates two concerns.
- Memory bound is best expressed as "zero, full stop" rather than "small, but tunable".
