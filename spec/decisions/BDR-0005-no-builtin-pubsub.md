---
id: BDR-0005
title: No built-in PubSub layer; stores use Phoenix.PubSub directly and handle_info/2
status: accepted
date: 2026-05-08
summary: Drop Musubi's `subscribe` block, `broadcast/4` socket helper, and `handle_broadcast/3` callback. Stores subscribe via Phoenix.PubSub.subscribe/2 inside mount and react via handle_info(msg, socket).
---

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Musubi does not define a built-in pub/sub layer

## Context

Earlier PRD drafts proposed a Musubi-owned PubSub layer with a `subscribe fn socket -> [...] end` declaration block, a `broadcast/4` helper on `socket`, and a `handle_broadcast/3` callback. The motivation was same-user cross-page sync. The design adds a Musubi-specific abstraction above `Phoenix.PubSub` that has to be learned, documented, and maintained.

LiveView itself does not own a PubSub layer — apps subscribe via `Phoenix.PubSub.subscribe/2` inside `mount/3` and handle inbound messages via `handle_info/2`.

## Behaviours Considered

### Option A: No built-in PubSub; use Phoenix.PubSub directly

Stores call `Phoenix.PubSub.subscribe/2` inside `mount/2`. Inbound messages arrive in the runtime mailbox and route to `handle_info(msg, socket)`. The `:handle_info` hook stage exists for cross-cutting tracing, but no Musubi primitives exist for subscribe or broadcast. Topic naming, message shape, and authorization are application concerns.

### Option B: Built-in subscribe block + handle_broadcast callback

`subscribe fn socket -> [...] end` declaration; `handle_broadcast(event, payload, socket)` callback; `broadcast(socket, topic, event, payload)` socket helper that wraps `Phoenix.PubSub.broadcast_from`. Adds Musubi-specific naming conventions.

### Option C: Built-in subscribe + raw handle_info

Keep `subscribe` block and topic-templating helpers but route inbound messages to `handle_info` (no `handle_broadcast`).

## Decision

Adopt Option A. Musubi does not define a PubSub abstraction. Stores integrate with whatever pub/sub mechanism the application uses (typically `Phoenix.PubSub`) by calling its subscribe API directly inside `mount/2` and handling inbound messages via `handle_info(msg, socket)`. The `:handle_info` hook stage exists for tracing/auditing.

## Rejected Alternatives

Option B was rejected because:
- It introduces a Musubi-specific layer over `Phoenix.PubSub` that does not gain functionality.
- The runtime already exposes `handle_info/2` for in-process messages; a separate `handle_broadcast/3` would duplicate the same delivery path under a different name.
- Topic naming, payload shape, and authorization are application concerns that Musubi cannot opinionate generically.
- Mirroring LiveView's "use the underlying PubSub directly" pattern lowers the learning curve and aligns with existing Phoenix idiom.

Option C was rejected for the same reasons as B but with a smaller surface — still adds a Musubi-specific subscribe macro that users must learn instead of just calling `Phoenix.PubSub.subscribe/2`.
