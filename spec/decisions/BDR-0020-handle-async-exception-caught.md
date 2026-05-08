---
id: BDR-0020
title: handle_async/3 exceptions are caught; runtime survives. Diverges from BDR-0003 let-it-crash for command handlers.
status: accepted
date: 2026-05-08
summary: A raise in handle_async/3 is caught by the runtime, recorded as [:arbor, :async, :exception], and the runtime continues. Justified because async result-processing bugs would otherwise crash the page on every result delivery.
---

**Feature**: domains/async/features/lifecycle.feature
**Rule**: handle_async/3 exceptions are caught; runtime survives

## Context

BDR-0003 established let-it-crash semantics for command handlers and `render/1`: a raise terminates the page runtime; the supervisor restarts; reconnect re-mounts from scratch. This is appropriate for synchronous user-driven flows where the client can immediately retry or perceive the disruption.

`handle_async/3` runs at unpredictable times — whenever an in-flight task's result arrives. A bug in `handle_async/3` (e.g., a `KeyError` against a `result` shape that the database has just returned) would, under let-it-crash, kill the page on every async completion. Long-lived pages with steady background work would face perpetual restart loops; the user would see a flapping UI.

LV does not catch exceptions in `handle_async/3` either; LV applications generally restart the LV process on async crash. Arbor diverges intentionally for this stage to give applications a more forgiving recovery path: surface the failure via telemetry, leave assigns untouched for that cycle, and let the application decide whether the next attempt should retry.

## Behaviours Considered

### Option A: Catch handle_async exceptions; runtime survives (Arbor extension)
Wrap `handle_async/3` invocation in a try/rescue. On exception: emit `[:arbor, :async, :exception]` with kind/reason/stacktrace; do not modify ctx for the cycle; continue processing subsequent messages. Diverges from let-it-crash.

### Option B: Let-it-crash (LV-aligned)
A raise terminates the runtime; the supervisor restarts; reconnect re-mounts. Consistent with BDR-0003.

### Option C: Catch only specific exception classes (e.g., timeouts and external-service errors); raise otherwise
Selective. Application policy lives in the runtime via configuration. More moving parts.

## Decision

Adopt Option A. Catch handle_async exceptions; emit telemetry; continue.

## Rejected Alternatives

Option B was rejected because:
- Async tasks frequently interact with external services whose failure modes are eventual: a one-off bug should not destroy the page.
- Long-running pages with steady async work would be brittle to any handler-side defect.
- The runtime can still log + alert via telemetry without ending the session.

Option C was rejected because:
- Categorizing "recoverable" vs "fatal" is a policy that doesn't generalize across applications.
- Adding a configuration knob for an edge case worsens the cost-to-benefit ratio.
- Option A's simple try/rescue + telemetry is enough to inform operators while staying robust.

This intentional divergence from BDR-0003's let-it-crash should be visible to operators via the `[:arbor, :async, :exception]` event. Future work may revisit if the divergence proves confusing.
