---
id: BDR-0004
title: All cross-cutting and per-node concerns use LV-style attach_hook; no separate middleware macro
status: accepted
date: 2026-05-09
summary: Arbor exposes one extension primitive — `attach_hook(ctx, id, stage, fun)` mirroring `Phoenix.LiveView.attach_hook/4`. There is no `middleware` macro for declarative per-store concerns. Authors attach all hooks (auth, validation, logging, feature flags, etc.) inside `mount/1` (or other handlers) on the store node that should host them.
---

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Hooks run in attachment order
**Rule**: Each store maintains its own hook table

## Context

Arbor's earliest drafts proposed two extension primitives — a `middleware Module` macro for declarative per-store concerns (auth, validation, logging) and `attach_hook` for runtime / cross-cutting concerns. Both ran in declaration / attachment order, with the same halt/cont protocol. The pair felt natural in Phoenix terms (Plug pipelines + LiveView attach_hook), but on examination it offered no functional capability that `attach_hook` alone did not, and forced authors to learn two near-identical mechanisms.

`Phoenix.LiveView` itself does not expose a `middleware` macro: LiveComponent has no equivalent at all, and the root LV uses `attach_hook` + `on_mount` only. Adopting LV-pure extension semantics in Arbor removes a concept the LV-aligned audience would otherwise have to learn for no behavior gain.

## Behaviours Considered

### Option A: Drop the `middleware` macro; use `attach_hook` for everything (LV-pure)

Every cross-cutting or node-local concern is attached at runtime via `attach_hook(ctx, id, stage, fun)`. Authors call `attach_hook` inside `mount/1` (or any handler) on the store node that owns the concern. Per-node concerns hook on that node's table; cross-node concerns hook on the root page store and pattern-match by path. Schema validation and render-output validation are runtime-attached default hooks installed by the runtime's mount path; authors can detach or replace them.

### Option B: Keep both `middleware Module` (declarative, compile-time) and `attach_hook` (runtime)

Two parallel mechanisms. `middleware` is sugar for compile-time stable concerns; `attach_hook` for dynamic / cross-cutting.

### Option C: Keep `middleware` only; drop `attach_hook`

Only declarative per-store middleware. Cross-node concerns must propagate via parent middleware traversal or root-only declarations. Strongly anti-LV.

## Decision

Adopt Option A. Drop the `middleware` macro entirely. `attach_hook(ctx, id, stage, fun)` is the sole extension primitive. Each store maintains its own hook table; child-attached hooks see only that node's events. Hooks return `{:cont, ctx}`, `{:halt, ctx}`, or `{:halt, reply, ctx}` (last only on `:before_command`).

## Rejected Alternatives

Option B was rejected because:
- `middleware Module` and `attach_hook` overlap in capability; offering both forces authors to choose without functional payoff.
- LV does not expose a `middleware` macro; aligning with LV reduces the learning curve for the dominant audience.
- One mechanism is easier to document, test, and instrument with telemetry than two.

Option C was rejected because:
- Cross-node concerns (audit, feature flags) become awkward without a runtime-attach mechanism.
- It would diverge from LV's hook-attached pattern.
- Implicit propagation rules (parent middleware reaches descendants) are hard to predict and were considered in earlier drafts; rejecting them here for the same reason.
