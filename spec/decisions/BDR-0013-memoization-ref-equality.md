---
id: BDR-0013
title: Child memoization uses socket.assigns map reference equality
status: accepted
date: 2026-05-08
summary: A child skips update/2 and to_state/1 when its socket.assigns map is reference-equal to the previous cycle's. Reused maps short-circuit; structurally-equal but distinct maps re-render.
---

## Scope

**Feature**: domains/runtime/features/render-contract.feature
**Rule**: A child whose socket.assigns is reference-equal to last cycle skips update/2 and to_state/1

## Reason

Reference equality on the `socket.assigns` map is cheap (a single Erlang term comparison) and matches the natural shape of immutable map updates: any `assign/2` call that genuinely changes a key produces a new map, and any handler that returns socket unchanged keeps the same reference. Deep-equal comparison would cost more than re-rendering most leaf components, and would still admit pathological cases (e.g., constructing structurally-equal maps from scratch each cycle). Phoenix LiveView's `__changed__` per-key tracking is more granular but significantly more complex to implement; ref equality is the smallest mechanism that captures the dominant case (handlers that don't touch this child's assigns) and integrates cleanly with the rest of Arbor's reduce-and-rebuild model. Authors who write no-op `assign/2` calls (e.g., `assign(socket, :status, socket.assigns.status)`) intentionally break ref equality and accept the extra render — this is treated as a controllable footgun, documented but not papered over.
