---
id: BDR-0011
title: A child that disappears from its parent's render is unmounted; reappearance triggers a fresh mount
status: accepted
date: 2026-05-08
summary: Identity does not survive an absence in render output. When (parent_path, module, id) is missing for one cycle and reappears later, the runtime treats it as a new node, mirroring Phoenix.LiveComponent.
---

## Scope

**Feature**: runtime/features/render-contract.feature
**Rule**: A disappeared child is unmounted; reappearance is a fresh mount with no preserved assigns

## Reason

Preserving identity across `:if`-driven gaps would require the runtime to keep "hidden" or "parked" child state indefinitely, with no clean rule for when to actually free it. Phoenix LiveView documents the same trade-off explicitly in `lib/phoenix_live_component.ex`: "A component is only discarded when the client observes it is removed from the page." Toggling visibility produces a fresh mount the next time the component appears. Adopting this rule keeps the identity contract crisp, frees memory predictably, and matches developer intuition about `:if`-driven mounting. Authors who genuinely need preserved state across an absence keep the placeholder rendered with a "hidden" flag in their own assigns rather than relying on runtime memory.
