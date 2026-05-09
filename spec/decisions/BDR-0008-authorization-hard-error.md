---
id: BDR-0008
title: Authorization denials use hook halt-with-payload (ok: false); never silent ok, never wire error category
status: accepted
date: 2026-05-09
summary: A denied command halts via {:halt, %{ok: false, reason: "unauthorized", ...}, socket} from a :before_command hook. The transport reply has channel status :ok and the payload carries an explicit ok: false flag. No silent ok with empty payload, and no wire enum of error categories (Arbor follows LV's let-it-crash on malformed inputs; auth denials are not malformed, they are graceful business outcomes).
---

## Scope

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Authorization halts emit a graceful reply payload, not a wire error

## Reason

A silent-ok downgrade for unauthorized commands seems convenient ("UI shouldn't expose denied buttons anyway") but is hostile to auditing and debugging — denied actions would disappear from logs and from client error handling. The reply must carry an explicit denial signal so both server logs and the client UI can react.

We considered (and rejected) a wire-level error category enum (`unauthorized`, `unknown_command`, etc.). Arbor mirrors LV's let-it-crash posture for malformed/impossible commands: an unknown path or undeclared command raises and the page runtime exits. Authorization denial, however, is a *graceful* business outcome — not a runtime fault — and crashing on it would be wrong. The middle ground is a hook halt-with-payload: the channel reply is `:ok` (no protocol-level error) but the payload carries `%{ok: false, reason: "unauthorized", ...}` so the client and audit telemetry both see the denial explicitly.

Application-specific shapes (`reason: "unauthorized" | "rate_limited" | ...`) live in the payload, not in a runtime enum, so applications can extend without runtime changes.
