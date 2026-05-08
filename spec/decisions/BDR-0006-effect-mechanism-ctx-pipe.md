---
id: BDR-0006
title: Effects accumulate via ctx-pipe helpers, not effect tuples
status: accepted
date: 2026-05-08
summary: Side effects (broadcast, persist_now) are functions on ctx that return a new ctx, mirroring LiveView's push_event/3 and friends. Drops the {:ok, ctx, effects: [...]} return shape.
---

## Scope

**Feature**: runtime/features/command-routing.feature
**Rule**: A successful handler returns either {:noreply, ctx} or {:reply, payload, ctx}

## Reason

Earlier PRD drafts allowed `{:ok, ctx, effects: [{:broadcast, ...}, {:persist_now}]}`. Effect tuples make composition awkward (effects accumulate across helpers, ordering becomes implicit), and break parity with `Phoenix.LiveView`'s consistent ctx-pipe pattern (`push_event/3`, `push_navigate/2`, `redirect/2`). Adopting `ctx |> broadcast(...) |> persist_now()` keeps effects observable in middleware and tests via the updated ctx, and matches the LV idiom developers already know.
