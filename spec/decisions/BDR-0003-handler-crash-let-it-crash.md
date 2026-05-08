---
id: BDR-0003
title: Handler crash terminates the page runtime; reconnect re-mounts from scratch
status: accepted
date: 2026-05-08
summary: No try/rescue around handlers. Page runtime dies on raise. Client reconnect mounts a fresh runtime whose mount/1 re-initializes state from scratch, mirroring Phoenix.LiveView. Snapshot persistence is not a built-in primitive (see backlog); applications that want session restoration implement it via hook-based persistence patterns.
---

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: A handler crash terminates the page runtime and the client reconnects via fresh mount

## Context

When a command handler raises (or a non-trivial invariant is violated mid-cycle), the runtime needs a recovery story. Options range from defensive try/rescue + error reply, to BEAM-idiomatic let-it-crash with supervisor restart, to per-node disable.

Phoenix LiveView (`channel.ex:132-135`) terminates the LV process on `phx_leave` with `{:stop, {:shutdown, :left}, state}`. Disconnects produce immediate process exit; reconnects spawn a fresh process and re-run `mount/3` and `handle_params/3` (`live_view.ex:43-44`). There is no in-process grace window or in-flight buffering.

## Behaviours Considered

### Option A: let-it-crash, LV-actual reconnect

Handler runs without try/rescue. Exception → page runtime exits → supervisor restarts. Transport drops; client reconnects; fresh runtime mounts and re-runs `mount/1` from scratch. Applications that want richer session restoration (e.g., persisted assigns, draft recovery) layer that on top via the hook-based persistence pattern. No reply is sent for the crashing command. Aligns with LV.

### Option B: Defensive try/rescue with `runtime_error` reply

Wrap handler in try/rescue. On exception, emit `{status: "error", payload: %{category: "runtime_error", ...}}` and keep runtime alive. Better UX for transient bugs; risk of carrying corrupt state.

### Option C: Per-node failure mode

Mark the failing store node as errored; subsequent commands to it reject; other nodes remain functional. Adds a node-level state machine.

### Option D: Grace window with reply/patch buffer (LV-deviation)

Runtime survives a transport drop for N seconds; buffers replies/patches for late-arriving reconnect. Adds buffering mechanics and memory pressure.

## Decision

Adopt Option A. No try/rescue. No grace window. No buffering. Reconnect → fresh mount → application-driven session restoration (if any). Drops the `runtime_error` wire category (no surviving runtime to send it).

## Rejected Alternatives

Option B was rejected because:
- Carrying state through an exception creates a class of subtle bugs where invariants silently degrade.
- Exception classes that *should* be recoverable belong in handler-controlled `{:reply, %{ok: false, ...}, ctx}` returns (see BDR-0002), not in runtime defense.
- BEAM's process model exists to localize crashes; bypassing it is anti-idiomatic.

Option C was rejected because per-node state-machine bookkeeping doubles complexity for a marginal recovery gain; clients must still resync after a node disable, so a full restart is cleaner.

Option D was rejected because LV does not buffer (`channel.ex:132`); deviating from LV adds memory pressure proportional to the grace window and creates a separate state machine for transport linger. Verified against LV source before rejecting.
