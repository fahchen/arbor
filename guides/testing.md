# Testing Stores

`Arbor.Testing` is the public test entry point for stores authored on top
of Arbor. It wraps `Arbor.Page.Server.start_link/1` with test-friendly
defaults and exposes the primary assertion surface, modelled on
`Phoenix.LiveViewTest`.

## Doctrine: assert through `render/2`, not `assigns/2`

Test the rendered wire-shape map — what the client would observe — not
internal `socket.assigns`. Renaming or splitting a field then trips the
test; assertions coupled to internal storage do not.

`assigns/2` is documented as an escape hatch for state that is not
surfaced through `render/1`. Reach for it sparingly.

## Minimum example

Suppose a store tracks a 1v1 fight:

```elixir
defmodule MyApp.Stores.RoomStore do
  use Arbor.Store, root: true

  state do
    field :hp, %{p1: integer(), p2: integer()}
    field :winner, :p1 | :p2 | :draw | nil
  end

  command :ko do
    payload :target, String.t()
    reply %{ok: boolean()}
  end

  @impl Arbor.Store
  def mount(_params, socket) do
    socket =
      socket
      |> Arbor.Socket.assign(:hp, %{p1: 100, p2: 100})
      |> Arbor.Socket.assign(:winner, nil)

    {:ok, socket}
  end

  @impl Arbor.Store
  def render(socket) do
    %{hp: socket.assigns.hp, winner: socket.assigns.winner}
  end

  @impl Arbor.Store
  def handle_command(:ko, %{"target" => "p2"}, socket) do
    socket =
      socket
      |> Arbor.Socket.assign(:hp, %{p1: 100, p2: 0})
      |> Arbor.Socket.assign(:winner, :p1)

    {:reply, %{"ok" => true}, socket}
  end
end
```

A focused test:

```elixir
defmodule MyApp.Stores.RoomStoreTest do
  use ExUnit.Case, async: true

  test "ko on p2 flips winner to p1" do
    page = Arbor.Testing.mount(MyApp.Stores.RoomStore, %{"room_code" => "AB12"})

    {:ok, %{"ok" => true}} =
      Arbor.Testing.dispatch_command(page, :ko, %{"target" => "p2"})

    assert Arbor.Testing.render(page) == %{
             hp: %{p1: 100, p2: 0},
             winner: :p1
           }
  end
end
```

## Wire shape: atoms stay atoms in `render/2`

`render/2` returns native Elixir terms — `:p1` stays an atom, the
`%{p1: ...}` map keeps atom keys. The JSON-string conversion happens
downstream on the way to the client (see "Wire Encoding: Atoms Become
Strings" in `Getting Started`). Tests are easier to read this way.

If you need to assert against the actual wire shape, pipe through
`Arbor.Wire.to_wire/1`:

```elixir
wire = page |> Arbor.Testing.render() |> Arbor.Wire.to_wire()
assert wire == %{"hp" => %{"p1" => 100, "p2" => 0}, "winner" => "p1"}
```

## Addressing child stores

`render/2`, `dispatch_command/4`, and `assigns/2` all accept an optional
`store_id` — the path from the root to the addressed node, matching the
shape of `Arbor.Socket.store_id/1`. The default `[]` addresses the root.

| `store_id`           | Addresses                              |
| :------------------- | :------------------------------------- |
| `[]`                 | root                                   |
| `["filters"]`        | root → child mounted with `id: "filters"` |
| `["cart", "i-42"]`   | root → cart child → its child `"i-42"` |

Each segment matches the `:id` passed to `Arbor.Child.child(Module, id: "...")`
inside the parent's `render/1` output. Segments are strings.

### Worked example

Parent + child store:

```elixir
defmodule MyApp.Stores.FiltersStore do
  use Arbor.Store

  state do
    field :query, String.t()
  end

  command :change_query do
    payload :query, String.t()
    reply %{ok: boolean()}
  end

  @impl Arbor.Store
  def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :query, "")}

  @impl Arbor.Store
  def render(socket), do: %{query: socket.assigns.query}

  @impl Arbor.Store
  def handle_command(:change_query, %{"query" => q}, socket) do
    {:reply, %{"ok" => true}, Arbor.Socket.assign(socket, :query, q)}
  end
end

defmodule MyApp.Stores.RootStore do
  use Arbor.Store, root: true

  state do
    field :filters, MyApp.Stores.FiltersStore.t()
  end

  @impl Arbor.Store
  def mount(_params, socket), do: {:ok, socket}

  @impl Arbor.Store
  def render(_socket) do
    %{filters: Arbor.Child.child(MyApp.Stores.FiltersStore, id: "filters")}
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end
```

Test that dispatches to the child and asserts on its rendered output:

```elixir
test "filter query updates through the child store" do
  page = Arbor.Testing.mount(MyApp.Stores.RootStore)

  {:ok, %{"ok" => true}} =
    Arbor.Testing.dispatch_command(
      page,
      :change_query,
      %{"query" => "shirt"},
      ["filters"]
    )

  assert Arbor.Testing.render(page, ["filters"]) == %{query: "shirt"}
end
```

### Lifecycle notes

- The child is mounted lazily by the resolver during the first render
  cycle, triggered automatically by `Arbor.Testing.mount/3`. By the
  time `dispatch_command/4` runs, the child is in the store table.
- Calling `dispatch_command/4` with a `store_id` for a child that was
  never rendered raises — the lookup fails fast.
- `Arbor.Testing.render(page)` at the root returns the raw `render/1`
  output, including the `%Arbor.Child{...}` placeholder. The
  placeholder is substituted with the child's rendered output later in
  the wire pipeline before the patch envelope ships to the client. Use
  `render(page, ["filters"])` to assert on the child's own output, or
  pipe through `Arbor.Wire.to_wire/1` to see the resolved wire shape.

## Push patches: handled automatically

By default `mount/3` sets the test process as the transport pid, so
push-patch envelopes arrive in the test mailbox. Most tests do not need
to consume them — `render/2` runs the store's `render/1` against the
current socket and is sufficient for state assertions.

If a test needs to observe patch sequencing (e.g. verifying a stream
operation was emitted), assert on the mailbox:

```elixir
assert_receive {:patch, %Arbor.Page.PatchEnvelope{ops: ops}}
```

## Teardown

`mount/3` uses `ExUnit.Callbacks.start_supervised!/1`, so the page
server is torn down with the test process. No manual cleanup needed.
