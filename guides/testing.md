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
`store_id` — the path from the root to the addressed node. The default
`[]` addresses the root.

```elixir
{:ok, _reply} =
  Arbor.Testing.dispatch_command(
    page,
    :select,
    %{"id" => "shirt"},
    ["filters"]
  )

assert Arbor.Testing.render(page, ["filters"]) == %{query: "shirt"}
```

The store_id matches `Arbor.Socket.store_id/1` — a list of local ids
from the root.

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
