---
id: BDR-0001
title: Outcome via transport reply, no application-layer ack envelope or sequence id
status: accepted
date: 2026-05-08
summary: Use Phoenix Channel ref-based replies for command outcomes; drop application-layer ack envelopes and client_seq.
---

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Each command receives exactly one transport reply correlated to its source push

## Context

Command outcomes (success or error) need to reach the originating client correlated to the original push. The runtime also delivers state diffs as separate patch pushes. Two questions arise: what carries the outcome, and how is it correlated to the request.

## Behaviours Considered

### Option A: Transport-level reply (Phoenix Channel ref)

Use the channel's ref-based reply mechanism. Every command push receives one reply with `{status: "ok" | "error", payload}`. Patches travel as separate pushes. The transport guarantees order and ref correlation.

### Option B: Custom application-layer ack envelope with client_seq

Define `{type: "ack", client_seq, status, error?}` as a server-pushed envelope. Client attaches a monotonic `client_seq` to each command and matches replies by seq. Patches reference `client_seq`.

### Option C: Both an ack envelope and a transport reply

Always emit both. Most explicit, but envelope volume doubles for no semantic benefit on a duplex transport.

## Decision

Adopt Option A. The transport's ref-based reply is sufficient and idiomatic on Phoenix Channels over WebSocket. Patches remain decoupled.

## Rejected Alternatives

Option B was rejected because:
- Layering `client_seq` on top of a transport that already provides ordered, ref-correlated replies duplicates transport mechanics with no benefit.
- Reconnect logic does not need command-level seq numbers — patch versioning (a separate concern) handles state resync.
- Adds bookkeeping in both server and client without enabling a new use case.

Option C was rejected because emitting both an ack envelope and a transport reply doubles the outcome envelopes per command without adding capability.
