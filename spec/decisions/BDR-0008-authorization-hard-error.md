---
id: BDR-0008
title: Authorization failure always produces a hard error reply; no silent no-op downgrade
status: accepted
date: 2026-05-08
summary: Denied commands always reply {status: "error", payload: %{category: "unauthorized", ...}}. No mode that converts denial into a synthetic ok no-op.
---

## Scope

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Authorization failure always produces a hard error reply with no silent downgrade

## Reason

A silent-ok downgrade for unauthorized commands seems convenient ("UI shouldn't expose denied buttons anyway") but is hostile to auditing and debugging — denied actions disappear from logs and from client error handling. Hard error replies make denials observable on both sides without requiring extra telemetry plumbing. If specific commands genuinely should silently succeed for unauthorized actors (e.g., feature-disabled placeholders), the application can express that explicitly via a `:before_command` hook returning `{:halt, %{ok: true}, ctx}`, which is auditable in code and in telemetry under category `hook_halt` if desired.
