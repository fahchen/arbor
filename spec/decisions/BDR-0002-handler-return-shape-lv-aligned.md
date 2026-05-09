---
id: BDR-0002
title: Handler return shape mirrors Phoenix.LiveView handle_event/3
status: accepted
date: 2026-05-08
summary: handle_command/3 returns {:noreply, socket} or {:reply, payload, socket}; no {:error, reason} variant.
---

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: A successful handler returns either {:noreply, socket} or {:reply, payload, socket}

## Context

Command handlers must report success and may carry a payload to the client. Earlier PRD drafts proposed three return shapes: `{:ok, socket}`, `{:ok, socket, effects: [...]}`, and `{:error, reason}`. LiveView's `handle_event/3` uses two: `{:noreply, socket}` and `{:reply, reply, socket}`, with errors raised or surfaced via socket-level state.

## Behaviours Considered

### Option A: LV-aligned, two return shapes

`{:noreply, socket}` and `{:reply, payload, socket}`. Handler-side business failures encode as `{:reply, %{ok: false, error: ...}, socket}` (status `ok` on the wire; the handler chose the shape). Hook halts produce error replies via the pipeline. Crashes terminate the runtime (see BDR-0003).

### Option B: Three return shapes including `{:error, reason}`

Add an explicit error return path that reaches the client as a wire error category (e.g., `handler_error`). Handlers can short-circuit without raising.

### Option C: Effect-tuple form

Return `{:ok, socket, effects: [...]}` with effects fired by the runtime.

## Decision

Adopt Option A. `{:noreply, socket}` and `{:reply, payload, socket}`. Effects move to socket-pipe helpers (see BDR-0006).

## Rejected Alternatives

Option B was rejected because:
- It creates two parallel error paths (handler return + hook halt) that surface differently on the wire, increasing the surface area clients must understand.
- Handler-side business failures are better expressed as semantically `ok` outcomes whose payload carries an `ok: false` flag — the request was processed; the business outcome was negative.
- Following LiveView precisely lowers the cognitive cost for developers already familiar with `handle_event/3`.

Option C was rejected because effect tuples complicate composition (effects accumulate across helpers, reordering becomes implicit) and break the LiveView analogy.
