---
id: BDR-0028
title: Uploads cannot be declared inside list, stream, or nested state blocks
status: accepted
date: 2026-05-19
summary: `upload :name, opts` is a compile-time singleton bound to a fixed name at a fixed path. It is rejected anywhere inside a list type spec, a stream block, a nested `field do ... end` block, or `state do`. For per-item dynamic uploads, use a child store per item: each child declares its own upload, and the `store_id` field on each upload op distinguishes the parent.
---

## Scope

**Feature**: domains/uploads/features/lifecycle.feature
**Rule**: Upload declarations are compile-time singletons; dynamic per-item capability uses child stores

## Reason

Three structural reasons make uploads incompatible with dynamic
containers:

1. **Name uniqueness.** `upload :name` registers exactly one slot per
   store. A list type spec with N items would require N slots, none of
   which has a compile-time name. There is no syntax that produces N
   names at compile time.

2. **Path stability.** Upload markers are auto-injected at the
   declaration path. List indices and stream item keys are runtime
   values; the framework cannot statically locate `/items/0/avatar`
   versus `/items/1/avatar` to produce the right marker, nor can the
   render-validation pass assert correctness without inspecting
   runtime data.

3. **Op routing.** Every `upload_ops` op carries `store_id`. A
   declaration buried inside a list element would have no stable
   `store_id` to encode; encoding the list index would conflate the
   transport-layer routing with the wire data tree.

For applications that genuinely need per-item uploads (per cart line
attachment, per row evidence, per gallery photo lifecycle), the
canonical pattern is a child store per item. Each child declares the
upload as a top-level singleton; the `store_id` field on every upload
op distinguishes the children:

```elixir
defmodule CartLineStore do
  use Musubi.Store
  attr :line_id, String.t(), required: true

  state do
    field :line_id, String.t()
  end

  upload :attachment, accept: ~w(.pdf), max_entries: 1

  def init(socket), do: {:ok, assign(socket, :line_id, socket.assigns.line_id)}
  def render(socket), do: %{line_id: socket.assigns.line_id}
end

defmodule CartStore do
  use Musubi.Store, root: true

  state do
    field :lines, [%{id: String.t()}]
  end

  def render(socket) do
    %{
      lines: Enum.map(socket.assigns.lines, fn line ->
        child(CartLineStore, id: "line-#{line.id}", line_id: line.id)
      end)
    }
  end
end
```

This composes cleanly: each `CartLineStore` instance has its own
`page.lines[i].attachment` `UploadHandle`, and the server keeps
`store_id: ["line-1"]`, `store_id: ["line-2"]`, etc. for routing.

For batch uploads where all entries share the same authorization and
limits, prefer a single upload with `max_entries: N` and disambiguate
entries by `client_name` or business metadata at consume time.
