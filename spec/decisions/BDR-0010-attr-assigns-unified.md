---
id: BDR-0010
title: Drop attr/assigns runtime split; unify into socket.assigns; attr stays as a compile-time annotation
status: accepted
date: 2026-05-08
summary: At runtime, parent-passed values and store-internal state share one socket.assigns map (LV-aligned). The attr macro stays for compile-time required/type/default validation, IDE hints, and codegen — but introduces no separate socket.attrs namespace.
---

**Feature**: domains/runtime/features/render-contract.feature
**Rule**: attr declares a parent-supplied assign with required, type, and default options

## Context

Earlier PRD drafts proposed a strict split between `socket.attrs` (parent-supplied, read-only on the child side) and `socket.assigns` (store-mutable internal state). Each child render started with two named bags. The split adds a concept and forces author code to decide which key lives where for every value.

`Phoenix.LiveView` and `Phoenix.LiveComponent` keep a single `socket.assigns` map. Parent-passed values flow into the same bag as internal state. The `Phoenix.Component.attr/3` macro is purely compile-time: it declares required, type, default, and slot information, drives compile warnings, and produces no runtime namespace.

## Behaviours Considered

### Option A: Unified socket.assigns; attr is compile-time only

Single bag at runtime. `attr` macro stays as compile-time annotation that:
- raises at the parent's render time when a `required: true` attr is missing from `child(...)`,
- supplies `default:` values into `socket.assigns` when the parent omits the key,
- contributes typespecs and codegen,
- is excluded from the resolved render output unless the author explicitly maps it into `state do`.

Function-valued attrs (callbacks) are declared as `attr :on_x, function(...), required: true` and live in `socket.assigns` like any other value.

### Option B: Strict socket.attrs / socket.assigns split (PRD draft)

Separate runtime namespaces. Authors read parent-passed values via `socket.attrs.foo` and internal state via `socket.assigns.bar`.

### Option C: Drop attr declarations entirely (full LV)

No attr macro. Parent passes any keys via `child(Module, id: ..., key: value, ...)`; child reads `socket.assigns.key`. Required-presence and type checking move to runtime errors or are dropped.

## Decision

Adopt Option A. `socket` carries one `assigns` map at runtime. `attr` macro is compile-time only.

## Rejected Alternatives

Option B was rejected because:
- LV proves the unified bag works without losing clarity.
- Two namespaces force authors to learn a contract that LV developers already do not use.
- Memoization would have to consider two namespaces rather than a single `socket.assigns.__changed__` map.
- Function-valued attrs (callbacks) end up split across namespaces in confusing ways.

Option C was rejected because:
- Required-presence is a real ergonomic gain that LV's `Phoenix.Component.attr/3` already provides.
- Typespecs and codegen need a declared shape for parent inputs.
- The cost of keeping `attr` as a pure compile-time annotation is small; the gains in tooling and error messages are real.
