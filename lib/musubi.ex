defmodule Musubi do
  @moduledoc """
  Server-authoritative, page-scoped runtime for Elixir/Phoenix with a
  framework-agnostic JavaScript client.

  ## The name

  `Musubi` (Japanese 結び) means *knot*, *bond*, or *connector* — the act
  of tying threads together at a point. In this runtime, every store is
  a musubi: a node that binds parent assigns to child renders, holds its
  own state, and lets reactive changes propagate through the bonds.

  ## What it does

  One BEAM process per connected page owns a tree of composable
  **stores**. Each store renders a piece of resolved state. When state
  changes, the runtime computes a structural diff against the previous
  wire output and pushes an RFC 6902 JSON Patch to the client over a
  `Phoenix.Channel`. The client materializes the patch into an
  immutable snapshot tree without prescribing a UI framework.

  Change tracking mirrors `Phoenix.LiveView`: per-key `__changed__`
  flags drive per-store memoization, so unchanged subtrees are reused
  verbatim and never re-rendered, re-serialized, or re-diffed.

  ## Core building blocks

    * `Musubi.Store` — define a store with `state do`, command
      handlers, optional async, and a `render/1` callback.
    * `Musubi.State` / `Musubi.Input` — typed state and command-input
      schemas.
    * `Musubi.Socket` — per-store state carrier with LV-aligned
      `assigns.__changed__` dirty tracking.
    * `Musubi.Page.Server` — the per-page runtime process.
    * `Musubi.Resolver` / `Musubi.Reconciler` — tree resolution and
      mount/update/reuse decisions.
    * `Musubi.Diff` — RFC 6902 add/remove/replace patch generator.
    * `Musubi.Wire` — protocol turning resolved Elixir terms into wire
      form.
    * `Musubi.Async` — `assign_async/3,4`, `start_async/3,4`,
      `cancel_async/2,3`, `stream_async/3,4`.
    * `Musubi.Stream` — LV-aligned streams with stable wire markers.
    * `Musubi.Testing` — test harness for stores.

  See `docs/PRD.md` and `spec/decisions/` for the design rationale.
  """
end
