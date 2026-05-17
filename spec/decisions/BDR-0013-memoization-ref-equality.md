---
id: BDR-0013
title: Child memoization uses LV-style __changed__ dirty-flag tracking
status: accepted
date: 2026-05-09
summary: Musubi mirrors Phoenix.LiveView's per-key change tracking. The `assign/3` macro records each mutated key in `socket.assigns.__changed__`; the runtime skips a child's `update/2` and `render/1` when none of the keys the child consumes appear in `__changed__`. After each render cycle the runtime resets `__changed__` to `%{}`.
---

## Scope

**Feature**: domains/runtime/features/render-contract.feature
**Rule**: A child whose consumed assigns are not in __changed__ skips update/2 and render/1

## Context

Earlier drafts of this BDR specified "reference equality" on the `socket.assigns` map. That phrasing is incorrect for Elixir: there is no exposed pointer comparison; `===` is structural. Two structurally-equal maps `===` true regardless of where they came from. A reference-equality memoization would either need an opaque BEAM term-identity primitive (none is exposed) or a deep structural compare (slow), and the wording would have been wrong either way.

Phoenix LiveView solves this with a `__changed__` field stored inside the assigns map (`socket.assigns.__changed__`). The `Phoenix.Component.assign/3` macro:

1. Reads the current value at `key`.
2. If the new value is `===` to the current value, it is a no-op (no entry written to `__changed__`).
3. Otherwise it writes the new value AND records `key => prior_value_or_true` in `__changed__`.

Reference: `Phoenix.Component.assign/3` and `Phoenix.LiveView.Utils.changed?/1,2` in the LV source. After rendering completes, the runtime resets `__changed__` to `%{}` for the next cycle.

## Decision

Adopt the LV pattern verbatim:

- `socket.assigns.__changed__` is a map of keys mutated since the previous render cycle.
- `assign/3` and `update/3` write to this map; explicit no-op writes (same value) record nothing.
- `Musubi.changed?(assigns, key)` and friends inspect the map; the runtime uses these to decide whether a child's `update/2` and `render/1` need to run.
- After each render cycle the runtime clears `__changed__` to `%{}` before processing the next message.

A child whose declared consumption set (via `attr` and explicit `assign` reads in its `render/1`) intersects `__changed__` runs; otherwise it short-circuits and reuses its prior resolved output.

## Rejected Alternatives

**Reference equality on the assigns map.** Rejected — Elixir does not expose a reference-equality primitive for maps. `===` is structural; a structural deep-compare on the assigns map would be O(n) and would still produce false negatives when authors construct structurally-equal but distinct maps.

**Deep-equal comparison.** Rejected — same cost as a structural compare, and per-cycle deep-equal at every child boundary becomes the dominant cost on a wide tree.

**No memoization.** Rejected — re-running every child's `render/1` on every cycle scales poorly with tree depth/width. The `__changed__` mechanism is the canonical LV-aligned answer.
