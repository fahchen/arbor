---
id: BDR-0022
title: reload_stream and stream_async(reset: true) are complementary recovery paths with distinct UX semantics
status: accepted
date: 2026-05-08
summary: reload_stream/2 silently refreshes a stream's contents without touching the AsyncResult; stream_async(reset: true) re-emits the loading state. Authors choose based on whether a loading flash is desired.
---

**Feature**: async/features/stream-async.feature
**Rule**: reload_stream and stream_async serve complementary recovery paths

## Context

Once a stream slot has been populated (typically via `stream_async`), the application may want to refresh its contents — e.g., after a webhook signals new data, after a user clicks "refresh", or after a stale window expires. Two scenarios drive different UX:

1. **Silent refresh**: the user is already looking at the data and just wants it updated. A loading spinner would feel like regression. The application wants the items replaced under the existing UI.

2. **Explicit reload**: the user actively requested a reload (e.g., navigating to a different filter), and the loading state is expected feedback.

Without distinguishing these, every refresh would either always flash the loading state (annoying) or never flash it (impossible to express "I'm intentionally reloading from scratch").

## Behaviours Considered

### Option A: Two complementary APIs with distinct semantics
- `reload_stream(ctx, name)` invokes the store's `reload_stream/2` callback, emits stream `reset + inserts`, leaves `AsyncResult` untouched. UX: silent refresh.
- `stream_async(ctx, name, fun, reset: true)` cancels the prior task, re-emits `AsyncResult.loading()`, runs the new task, populates the stream on completion. UX: loading flash.

Authors choose based on the desired UX. Both paths share the same wire format for stream content.

### Option B: Only `stream_async(reset: true)`; drop `reload_stream/2`
Every refresh re-emits loading. Simpler API surface. Loses the silent-refresh affordance.

### Option C: Only `reload_stream/2`; drop the AsyncResult-flash variant
Authors emit AsyncResult transitions manually if they want a loading flash. More boilerplate; less ergonomic.

## Decision

Adopt Option A. Both APIs coexist with documented complementary roles.

## Rejected Alternatives

Option B was rejected because the silent-refresh UX is common (auto-refresh on visibility change, websocket-pushed updates) and forcing a loading flash for those flows feels regressive.

Option C was rejected because the explicit-reload UX is also common and authors should not have to write `assign(ctx, :foo, AsyncResult.loading()) |> stream_async(...)` boilerplate.

The runtime documents both paths and recommends `reload_stream/2` for periodic/silent refreshes and `stream_async(reset: true)` for user-initiated reloads.
