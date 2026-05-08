---
id: BDR-0014
title: Pure structural minimal JSON-diff; no array-replace strategy or subtree-replace fallback
status: accepted
date: 2026-05-08
summary: The diff engine emits whatever the JSON-diff library produces — minimal add/remove/replace ops — with no thresholds, no whole-array replace heuristic, and no subtree-replace fallback. Bandwidth tuning is deferred.
---

**Feature**: domains/replication/features/json-patch-diff.feature
**Rule**: The diff engine emits the structural minimal diff with no fallback to subtree replace

## Context

JSON Patch (RFC 6902) without `move` op produces verbose diffs for array reorders: a 100-element list whose elements all shift produces 100 `replace` ops. Earlier PRD drafts and discovery notes considered:

- **Whole-array replace** for any list change — bounded but loses bandwidth on tiny edits.
- **Subtree-replace fallback** triggered by op count or byte threshold — bounded under load but adds tunables and a non-deterministic decision boundary.
- **Hybrid per-element / whole-array** based on whether positions shifted — better in many cases but adds branchy logic and edge cases.
- **Pure minimal diff** — emit whatever the structural diff produces with no special cases.

The Arbor wire payload is typed JSON, not HTML; the diff is comparatively cheap to compute server-side, and clients applying RFC 6902 ops scale linearly in op count. Most production state changes are small (single-field edits dominate); the pathological case (massive reorders) is rare and can be handled by future optimization once measured.

## Behaviours Considered

### Option A: Pure minimal diff
Emit whatever the JSON-diff library produces. No thresholds. No special cases.

### Option B: Whole-array replace heuristic
Any change inside an array → emit `{op: "replace", path: "/array_path", value: <new array>}`.

### Option C: Subtree-replace fallback above a threshold
Compute the minimal diff; if the resulting op count or serialized byte size exceeds a threshold, emit a single `replace` of the smallest-enclosing subtree instead.

### Option D: Hybrid per-element / whole-array
For each array, compare positions; if elements stayed in place (no shifts), emit per-element ops; if positions shifted, emit whole-array replace.

## Decision

Adopt Option A. Pure structural minimal diff. No thresholds. No special cases.

## Rejected Alternatives

Option B was rejected because:
- It loses bandwidth on common cases (single-field edits to a long list).
- It defeats client-side optimizations that key on minimal ops (e.g., per-element React-style reconciliation).

Option C was rejected because:
- It adds a tunable that must be measured per workload.
- It introduces a non-deterministic boundary (small input changes around the threshold flip the wire shape).
- The MVP has no measured triggering scenario.

Option D was rejected because:
- It adds branchy logic and edge cases (interleaved insert + reorder is hard to classify).
- The wire-shape decision is not predictable from client side.
- Future optimization can revisit this after benchmarks point at it.

The pathological large-reorder case can be addressed later as a targeted optimization (e.g., introduce `move` op support, or per-store `:replace_threshold` opt-in). The MVP avoids the tunable.
