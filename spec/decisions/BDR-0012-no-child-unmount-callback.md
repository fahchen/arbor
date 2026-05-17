---
id: BDR-0012
title: Child stores have no unmount/terminate callback; the root page store may define terminate/2
status: accepted
date: 2026-05-08
summary: Mirrors Phoenix.LiveComponent (no terminate hook) and Phoenix.LiveView root (terminate/2 only on the root). Async tasks clean up via Task.Supervisor links; PubSub subscriptions live on the root process.
---

## Scope

**Feature**: domains/runtime/features/render-contract.feature
**Rule**: Lifecycle for child stores is mount(socket) and update(new_assigns, socket); no per-child unmount callback
**Rule**: The root page store may define terminate(reason, socket)

## Reason

`Phoenix.LiveComponent` deliberately does not expose an unmount/terminate callback — the framework discards the component when the page no longer renders it. `Phoenix.LiveView` exposes `terminate(reason, socket)` only on the root LV process (the GenServer that owns the page). Musubi mirrors that split: child stores are not GenServers and have no per-instance lifecycle to clean up beyond what the runtime already handles (Task.Supervisor cancels async tasks via process linkage; PubSub subscriptions are owned by the root page runtime, not by individual child stores). Authors who genuinely need cleanup tied to a child's disappearance can express it via the parent's render logic (e.g., the parent runs cleanup before its next render decides to drop the child). Keeping child stores callback-free reduces the API surface and matches an existing battle-tested precedent.
