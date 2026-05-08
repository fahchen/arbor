---
id: BDR-0007
title: Pipeline order follows declaration; schema validation is itself a middleware
status: accepted
date: 2026-05-08
summary: No fixed magic order. Hooks and per-store middleware run in declaration / attachment order. Arbor.Middleware.ValidateCommandSchema is a built-in middleware module, default-attached but replaceable.
---

## Scope

**Feature**: runtime/features/command-routing.feature
**Rule**: Hooks and middleware run in declaration and attachment order

## Reason

A fixed magic order ("validation always first, auth second, handler last") removes the developer's ability to rearrange concerns — for example, attaching a tracing hook that observes the *raw* payload before validation, or running a custom rate-limit middleware before schema validation. Treating schema validation as a regular middleware module (`Arbor.Middleware.ValidateCommandSchema`) gives developers the same composition primitives they use for everything else and removes a special-case from the runtime. The default attachment ensures schemas are enforced unless explicitly replaced.
