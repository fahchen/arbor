---
id: BDR-0023
title: Root render/1 short-circuits when the root socket is unchanged
status: proposed
date: 2026-05-17
summary: The resolver reuses cached root raw/resolved output on child-only cycles, skipping root `render/1` and its render-stage hooks when the root socket and root streams are unchanged.
---

## Scope

**Feature**: domains/runtime/features/render-contract.feature
**Rule**: A root with no own changes short-circuits its render/1

## Context

Today `Arbor.Resolver.render_store/3` calls `socket.module.render(socket)` unconditionally for every store node, including the root (`lib/arbor/resolver.ex:109` at the time of writing). Child nodes already have a reuse gate in `Arbor.Reconciler.reconcile_child/4`: when the parent did not change the child's consumed assigns, the child has no internal socket mutations, and the child has no pending stream changes, the runtime reuses the child's cached `resolved_state` instead of invoking `update/2` and `render/1` again.

The root has no parent boundary to provide that gate. As a result, every render cycle recomputes the root output tree even when the root socket is clean and only a descendant mutated. For expensive roots this means repeated work on every child-only update:

- root `render/1` runs again even though its own assigns are unchanged
- the identical root output is serialized to wire form again
- the diff engine compares an equivalent root tree again

This is observable because short-circuiting the root also changes hook behaviour. If the root render is skipped, the root socket's `:after_render` and `:after_serialize` hooks will not fire for that cycle. `Stream.drain_and_prune/1` and `Socket.reset_changed/1` still need to run each cycle as runtime cleanup invariants.

## Decision

When all of the following are true for the root entry:

- `socket.assigns.__changed__` is empty
- the root socket has no pending changed streams
- the root entry already has a cached `resolved_state`
- the root entry already has a cached pre-resolution `raw_state`

the resolver reuses the cached root tree instead of invoking the root module's `render/1`.

The cached value used for reuse is the root entry's `raw_state` — the Elixir-shaped value returned by `render/1` before child resolution, stream placeholder normalization, store-id injection, wire conversion, or render-stage hooks. The resolver still walks that cached `raw_state` through child resolution so descendant updates propagate into the final root output for the current cycle.

On such a cached root cycle:

- the root's `render/1` is not invoked
- the root's `:after_render` hooks do not fire
- the root's `:after_serialize` hooks do not fire
- `Stream.drain_and_prune/1` still runs on the root socket
- `Socket.reset_changed/1` still runs on the root socket

Child nodes keep their existing behaviour. A dirty child still updates or renders as needed while the unchanged root simply reuses its cached raw tree as the traversal seed.

This decision adds a `raw_state` cache field to the store-table entry so the resolver can distinguish:

- `raw_state`: pre-resolution `render/1` return value, reused for root traversal
- `resolved_state`: fully resolved Elixir output, reused by child memoization
- `wire_state`: serialized output used by diffing

## Why This Is Safe

The root render-stage hooks observe the render output. If the root socket is clean and the root has no pending stream changes, the root's own `render/1` result is contractually identical to the prior cycle's result. Re-firing `:after_render` or `:after_serialize` would therefore repeat an identical observation, not expose new root information.

The trade-off is intentional: Arbor prioritizes skipping redundant root work over preserving per-cycle render-stage hook invocation on unchanged root state. This is similar in spirit to Phoenix LiveView's change tracking, where user callbacks still run for the message that mutated state, but rendering work is skipped when assigns are unchanged. Arbor differs in naming and lifecycle shape, but the same boundary applies here: message-stage hooks remain per-message, render-stage hooks remain tied to actual rendering.

This safety claim assumes `render/1` obeys the existing contract that it is free of observable side effects and is a deterministic function of socket state. A root `render/1` that reads wall clock time, random values, process dictionary state, or other hidden inputs is already outside the contract; caching does not attempt to preserve behaviour for such implementations.

## Rejected Alternatives

### Always render (status quo)

Rejected because it forces all child-only cycles to pay the root's render, wire-conversion, and diff-input cost even when the root socket is unchanged.

### Cache `wire_state` only

Rejected because it avoids only the final serialization step. The expensive root `render/1` call would still run, and child reconciliation could not be re-driven from wire-form data.

### Per-field render output memoization

Rejected because it is much more invasive. It would require finer-grained template or field dependency analysis similar to LiveView's compile-time render tracking, which Arbor does not currently have.

## Migration

Existing root-level `:after_render` or `:after_serialize` hooks that rely on firing once per render cycle must move to a message-stage hook instead:

- `:after_command`
- `:handle_async`
- `:handle_info`

Those hooks still fire when their corresponding message/callback runs, even if the root render is short-circuited afterward.
