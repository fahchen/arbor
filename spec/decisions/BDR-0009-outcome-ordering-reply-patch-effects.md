---
id: BDR-0009
title: Outcome ordering is reply, then patch push, then effects
status: accepted
date: 2026-05-08
summary: Transport reply ships first, the patch push follows, side effects (out-of-band broadcasts, application hook-driven persistence, etc.) fire last. Keeps perceived command latency minimal; effects do not block client visibility.
---

## Scope

**Feature**: runtime/features/command-routing.feature
**Rule**: A successful command's outcome is delivered as reply, then patch push, then effects

## Reason

The client's perceived latency for a command is the time-to-reply. Sending the reply before the patch keeps that interval minimal and removes any dependency on serializing the diff. The patch follows immediately so the next render is consistent. Side effects (broadcasts to peers, application-driven persistence via hooks, etc.) are non-blocking from the originating client's perspective, so firing them last avoids inflating the originator's wait. The brief gap between reply and patch is sub-frame in practice and is acceptable as a known property of the contract.
