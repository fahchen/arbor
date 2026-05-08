---
id: BDR-0004
title: Cross-cutting concerns attach via LV-style attach_hook; per-store middleware stays node-local
status: accepted
date: 2026-05-08
summary: Per-store `middleware` declarations apply only to the addressed node. Cross-node concerns use `attach_hook(ctx, id, stage, fun)` mirroring Phoenix.LiveView.attach_hook/4.
---

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Hooks and middleware run in declaration and attachment order
**Rule**: Each store maintains its own hook table

## Context

Cross-cutting concerns (audit logging, feature flags, rate limiting, tracing) must observe events across multiple store nodes without each node re-declaring middleware. The earlier PRD draft considered "parent middleware reaches descendants" semantics where a parent's `middleware` block ran for any command on its subtree.

Phoenix LiveView solves this with `attach_hook/4` (`lifecycle.ex`): hooks register on the LV process at runtime, see all events for that process, and pattern-match to filter. LiveComponents support a subset of stages with their own hook tables.

## Behaviours Considered

### Option A: Per-store middleware + LV-style attach_hook

Each store's `middleware ...` declarations run only for commands addressed to that node. Cross-cutting code attaches hooks at the root page store (or any ancestor) via `attach_hook(ctx, id, stage, fun)`. Hook stages: `:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_render`. Returns `{:cont, ctx}`, `{:halt, ctx}`, or `{:halt, reply, ctx}` (last only on `:before_command`). Each store maintains its own hook table.

### Option B: Parent middleware reaches descendants

A parent's `middleware` block automatically runs for any command on its subtree. Composition is implicit; ordering walks root-to-target.

### Option C: Page-runtime-level only (no per-store hooks)

All hooks attach at the root; per-store middleware exists only at the addressed node. Disallow `attach_hook` on child stores.

## Decision

Adopt Option A. Per-store middleware is node-local; cross-cutting concerns use `attach_hook`. Each store has its own hook table; child-attached hooks see only that node's events.

## Rejected Alternatives

Option B was rejected because:
- Implicit cross-node middleware behavior makes it hard to predict which middleware runs for a given command without walking the tree.
- Function-call chains grow with tree depth, hurting performance predictability.
- Parents would need to know about descendants' commands to filter usefully — leaks abstraction.
- Pattern-matching inside an attached hook is more explicit than implicit ancestry traversal.

Option C was rejected because LiveComponent precedent supports per-component hooks, and disallowing them would force boilerplate at the root for child-local concerns. Mirroring LV's split is more flexible and more familiar.
