---
id: BDR-0019
title: start_async same-name silently overwrites the tracked ref; older task lazy-discards on completion
status: accepted
date: 2026-05-08
summary: A second start_async with the same name does not cancel the prior task. The runtime swaps the tracked ref; the prior task continues running but its result is dropped via ref-prune when it arrives. Mirrors Phoenix.LiveView.
---

**Feature**: async/features/lifecycle.feature
**Rule**: A second start_async with the same name silently overwrites the prior tracked ref

## Context

A store may call `start_async(ctx, :foo, ...)` twice in quick succession (e.g., a click that triggers a fresh data load before the previous one completes). The runtime needs a deterministic policy for how the two overlap. Three behaviours were considered:

- **Implicit cancel** of the prior task before spawning the new one.
- **Concurrent allowed**: both tasks run; both results route to `handle_async/3`; the application is responsible for de-duping.
- **Silent overwrite**: track only the latest task; the older task continues running but its result is dropped on arrival because its ref no longer matches.

`Phoenix.LiveView.Async.run_async_task` (`async.ex:279`) implements silent overwrite by `Map.put`-ing the new `{ref, pid, kind}` over the old one in `private_async`. `prune_current_async/3` (`async.ex:416`) checks ref equality and rejects stale results. The older task is not actively killed.

## Behaviours Considered

### Option A: Silent overwrite + lazy discard (LV-aligned)
New start_async replaces the tracked ref. Older task runs to completion; its result message arrives, fails the ref-prune check, and is discarded. No active cancel.

### Option B: Implicit cancel of the prior task
On second `start_async` with the same name, runtime calls `cancel_async/3` first, then spawns the new task. Predictable resource cleanup; one extra `:DOWN` message and an `[:arbor, :async, :cancel]` event.

### Option C: Allow concurrent tasks per name
Track multiple `(ref, pid)` entries per name. `handle_async/3` is invoked once per result. Application must filter or de-dupe.

## Decision

Adopt Option A. Silent overwrite + lazy discard. Matches LV.

## Rejected Alternatives

Option B was rejected because:
- Diverges from LV without a load-bearing reason.
- The "older task continues" outcome is acceptable: tasks linked to the runtime die with it; otherwise they consume resources only briefly.
- Active cancel adds wire telemetry noise (`:cancel` events for every fast-double-click) without changing user-visible behavior.

Option C was rejected because:
- Application-level de-dup is the wrong place to encode "I want only the latest answer".
- Multiple result deliveries to one named slot violates the principle of least surprise.
- Real concurrency (multiple distinct in-flight tasks) is best modelled with distinct names rather than one name with N entries.
