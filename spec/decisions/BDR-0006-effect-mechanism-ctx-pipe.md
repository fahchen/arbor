---
id: BDR-0006
title: Effects accumulate via socket-pipe helpers, not effect tuples
status: accepted
date: 2026-05-08
summary: Side effects (e.g., out-of-band broadcasts, hook-implemented persistence) are functions on socket that return a new socket, mirroring LiveView's push_event/3 and friends. Drops the {:ok, socket, effects: [...]} return shape.
---

## Scope

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: A successful handler returns either {:noreply, socket} or {:reply, payload, socket}

## Reason

Earlier PRD drafts allowed `{:ok, socket, effects: [{:broadcast, ...}, {:persist_now}]}`. Effect tuples make composition awkward (effects accumulate across helpers, ordering becomes implicit), and break parity with `Phoenix.LiveView`'s consistent socket-pipe pattern (`push_event/3`, `push_navigate/2`, `redirect/2`). Adopting `socket |> broadcast(...) |> some_app_effect()` keeps effects observable in hooks and tests via the updated socket, and matches the LV idiom developers already know. (Note: built-in effect helpers may include broadcast-style operations; persistence-style helpers are application-defined since persistence is not a built-in primitive — see `spec/backlog.md`.)
