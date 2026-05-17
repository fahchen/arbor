---
id: BDR-0007
title: Pipeline order follows hook attachment order; schema validation is itself a runtime-attached hook
status: accepted
date: 2026-05-09
summary: No fixed magic order. Hooks run in attachment order. The runtime attaches built-in hooks (e.g., `Musubi.Hooks.ValidateCommandSchema` at `:before_command`, `Musubi.Hooks.ValidateRender` at `:after_serialize`) by default during mount; authors may detach or replace them. There is no separate `middleware` macro (see BDR-0004).
---

## Scope

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: Hooks run in attachment order

## Reason

A fixed magic pipeline order ("validation always first, auth second, handler last") removes the developer's ability to rearrange concerns — for example, attaching a tracing hook that observes the *raw* payload before validation, or running a custom rate-limit hook before schema validation. Treating schema validation as a regular hook (`Musubi.Hooks.ValidateCommandSchema`, runtime-attached on `:before_command` during the runtime's mount path) gives developers the same composition primitives they use for everything else and removes a special-case from the runtime. The default attachment ensures schemas are enforced unless explicitly detached or replaced.

This decision pairs with BDR-0004 (drop `middleware` macro): there is one extension primitive — `attach_hook` — and one ordering rule — attachment order.
