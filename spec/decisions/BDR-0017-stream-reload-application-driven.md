---
id: BDR-0017
title: Stream reload is application-driven via ctx |> reload_stream(name); runtime never auto-invokes
status: accepted
date: 2026-05-08
summary: The runtime exposes a reload_stream(ctx, name) helper that triggers the store's reload_stream/2 callback, but never auto-invokes it. Aligns with BDR-0015 (no application-level resync) — recovery is the application's call.
---

## Scope

**Feature**: streams/features/lifecycle.feature
**Rule**: Stream reload is application-driven via ctx |> reload_stream(name)

## Reason

A runtime-driven reload would need a triggering signal — version mismatch, idle timeout, reconnect handshake — and Arbor explicitly removed those signals in BDR-0015. With page runtimes 1:1 to transport (BDR-0003) and reconnect always producing a fresh `mount/3`, the runtime has no point at which it would decide on its own to invoke `reload_stream/2`. Pushing the trigger to the application keeps control where the policy lives: the store author knows when stale data hurts UX (e.g., long-idle window, navigation to a stale view, manual refresh button) and can call `ctx |> reload_stream(name)` from any handler. The helper produces a deterministic envelope (`reset` + bulk inserts) that the client treats like any other stream op sequence.
