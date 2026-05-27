---
id: BDR-0029
title: Command replies are native at the runtime boundary; wired at transport egress
status: accepted
date: 2026-05-27
summary: The command pipeline returns the reply in native Elixir shape (atom keys, structs, atom values), symmetric with render/1. Musubi.Wire.to_wire/1 is applied at the transport egress, the same boundary that serializes patch envelopes. Reply-schema validation still runs against the wire form internally. Revises #57 (v0.4.0), which wired the reply inside the page server.
---

## Scope

**Feature**: domains/runtime/features/command-routing.feature
**Rule**: A successful command's reply is returned native from the runtime and wire-serialized at the transport egress

## Context

Musubi documents a clean split for render output: `:after_render` runs on the
resolved Elixir term (atom keys, structs, atom values); `:after_serialize` runs
on the wire term (string keys, plain maps, atoms-as-strings) produced by
`Musubi.Wire.to_wire/1`. `render/1` returns the native term and the JSON-string
transformation happens on the way out to the client, not inside `render/1`.

#57 (v0.4.0) made command **replies** diverge from this model: the page server
wired the reply inside its command return —
`{:ok, Musubi.Wire.to_wire(reply), next_state, envelope}`. Consequently
`Musubi.Page.Server.command/4`, `command_by_name/4`, and
`Musubi.Testing.dispatch_command/3` exposed the wire term (string keys,
stringified atoms) rather than the native term. This created two problems:

1. **Reply/render asymmetry.** The runtime boundary returned wire-shaped replies
   but Elixir-shaped renders — inconsistent and surprising for the same runtime.
2. **Wire representation leaked into the runtime/test API.** Consumer tests were
   forced to assert wire artifacts (`%{"status" => "ok"}`) for replies instead of
   native domain values (`%{status: :ok}`), or to call `Musubi.Wire.to_wire/1` in
   test code. `to_wire` belongs to the runtime/protocol, not application/test code.

## Behaviours Considered

### Option A: Wire the reply inside the page server (the #57 behavior)

The command pipeline returns the wire term. Validation is trivially "free"
because the reply is already wired. But the runtime/test API exposes wire
artifacts and diverges from render.

### Option B: Native at the runtime boundary, wired at transport egress

The command pipeline returns the native reply. The transport adapter applies
`Musubi.Wire.to_wire/1` on the way out to the client — the same egress boundary
that already serializes patch envelopes (`PatchEnvelope.to_wire/1`). Reply-schema
validation wires internally for the validation check only and leaves the returned
value native.

## Decision

Adopt Option B.

- `handle_command/3` keeps returning `{:reply, payload, socket}` with `payload`
  in native Elixir shape (BDR-0002) — unchanged.
- `Musubi.Page.Server` returns the reply in native shape to its caller (the
  transport adapter and `Musubi.Testing.dispatch_command/3`). It does **not**
  apply `Musubi.Wire.to_wire/1` to the reply. This holds for both the handler
  reply and a `:before_command` halt reply.
- `Musubi.Transport.Channel` and `Musubi.Transport.ConnectionChannel` apply
  `Musubi.Wire.to_wire/1` to the reply on egress to the client. **Client-observable
  behavior is unchanged**: the client still receives the wire-shaped (string-key,
  stringified-atom) JSON reply, ref-correlated (BDR-0001) and ordered
  reply→patch→effects (BDR-0009).
- `Musubi.Testing.dispatch_command/3` returns the native reply, symmetric with
  `Musubi.Testing.render/2`.

Reply-schema validation continues to run against the **wire form**:
`Musubi.Hooks.ValidateReplySchema` converts the reply with `Musubi.Wire.to_wire/1`
once for the validation check and leaves the returned reply untouched. So
atom-valued and nested reply-field validation (the stated #57 benefit) is
preserved while the returned value stays native. `:after_command` hooks and the
`[:musubi, :auth, :deny]` telemetry continue to observe the native reply.

## Rejected Alternatives

Option A was rejected because it breaks reply/render symmetry and leaks the wire
representation into the runtime and test API. Validation does not require the
returned value to be wire-shaped — the validator can wire internally for the
check alone, so the convenience of Option A does not justify the asymmetry.

## Relates To

- BDR-0001 — outcome via transport reply (ref-correlation preserved)
- BDR-0002 — handler return shape (`{:reply, payload, socket}` native — unchanged)
- BDR-0009 — outcome ordering reply→patch→effects (preserved)
