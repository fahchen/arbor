# Persistence pattern (application-owned)

Arbor does not ship an `Arbor.Persistence` module, behaviour, or adapter. This is a deliberate scope decision recorded in `spec/backlog.md`: persistence is an application concern, not a runtime primitive. Hook stages and the `socket` extension points already give applications everything they need.

This document is the reference for that pattern: load on `mount/1`, save on `attach_hook(:persist, :after_command, …)`.

## Why hooks, not a built-in adapter

- **Topology varies.** Some stores save full snapshots; some append events; some cache and let a background worker write through. A built-in adapter forces a single shape.
- **Authorization is application-specific.** Who can persist what for whom is policy, not transport.
- **Hooks already have the right surface.** `:after_command` runs after `handle_command/3` returns. The store's resolved post-command `socket` is in scope. That is the natural save point.
- **`mount/1` is the natural load point.** It already runs once per page mount before the first render and can read from any store the application controls.

## Save: `attach_hook(:persist, :after_command, …)`

`:after_command` hooks are arity 3, called as `(command_name, payload, socket)`. Return shape is `{:cont, socket}` or `{:halt, socket}`. `use Arbor.Store` does **not** import socket / lifecycle helpers — call the fully-qualified `Arbor.Socket.*` and `Arbor.Lifecycle.*` functions.

```elixir
defmodule MyApp.Stores.CartStore do
  use Arbor.Store

  state do
    field :items, list(CartItemState.t())
  end

  command :add_item do
    payload :sku, String.t()
  end

  def mount(socket) do
    items = MyApp.Storage.load_cart(socket.assigns.cart_id) || []

    socket =
      socket
      |> Arbor.Socket.assign(:items, items)
      |> Arbor.Lifecycle.attach_hook(:persist, :after_command, &persist/3)

    {:ok, socket}
  end

  defp persist(_command_name, _payload, socket) do
    MyApp.Storage.save_cart(socket.assigns.cart_id, socket.assigns.items)
    {:cont, socket}
  end

  def handle_command(:add_item, %{"sku" => sku}, socket) do
    {:noreply, Arbor.Socket.update_assign(socket, :items, &[CartItemState.new(sku) | &1])}
  end

  def to_state(socket), do: %{items: socket.assigns.items}
end
```

### Selective save

Hooks see the command name, so the application can opt out of persistence for read-only commands or for commands that already wrote to storage themselves.

```elixir
defp persist(:refresh, _payload, socket), do: {:cont, socket}
defp persist(_command, _payload, socket) do
  MyApp.Storage.save_cart(socket.assigns.cart_id, socket.assigns.items)
  {:cont, socket}
end
```

### Failure handling

If persistence fails and the application wants the user-visible error to surface, raise inside the hook — the page server will crash per BDR-0003 let-it-crash. If the application wants to swallow and retry asynchronously, log inside the hook and continue. There is no built-in retry.

```elixir
require Logger

defp persist(_command, _payload, socket) do
  case MyApp.Storage.save_cart(socket.assigns.cart_id, socket.assigns.items) do
    :ok -> {:cont, socket}
    {:error, reason} ->
      Logger.error("cart persist failed: #{inspect(reason)}")
      {:cont, socket}
  end
end
```

## Load: inside `mount/1`

`mount/1` runs once per page mount on the root store and once per child mount; both have full access to `socket.assigns`. Load there:

```elixir
def mount(socket) do
  case MyApp.Storage.load_cart(socket.assigns.cart_id) do
    {:ok, items} -> {:ok, Arbor.Socket.assign(socket, :items, items)}
    :error -> {:ok, Arbor.Socket.assign(socket, :items, [])}
  end
end
```

If the load is slow, prefer `Arbor.Async.assign_async/3`:

```elixir
def mount(socket) do
  socket =
    socket
    |> Arbor.Socket.assign(:items, [])
    |> Arbor.Async.assign_async(:loaded, fn -> {:ok, MyApp.Storage.load_cart(socket.assigns.cart_id)} end)

  {:ok, socket}
end
```

## Stream slot reload

For a stream slot, refresh in-session via `stream(socket, :messages, items, reset: true)` or `stream_async(socket, :messages, fun, reset: true)`. The persistence pattern still applies — load fresh items inside `mount/1` (or whichever handler triggers a refresh) and emit them through the stream API. The runtime forgets stream values after flush; only the per-stream slot config (item_key fn, limit, ref counter) is retained on the socket. The client owns the materialized list.

## Snapshot vs append-only

Both shapes work with the same primitives:

- **Snapshot** — overwrite on every `:after_command` write. Simple. Higher write cost. Easy reload (single read at mount).
- **Append-only** — write each command + payload to an event log; rebuild state at mount by replaying. More flexible. Reload cost grows with history. Use when audit/event sourcing is already part of the application.

Arbor doesn't pick. Both compose with the same hook stages.

## Reconnect = fresh mount

Per BDR-0003, reconnect rebuilds the page from scratch. There is no in-memory checkpoint that survives a transport drop. The load path is the only restoration mechanism. This is intentional: the runtime never tries to be a durable store; durability is delegated entirely to the application's persistence layer.

## What you do not need to do

- Do **not** call into the runtime to persist on its behalf — there is no API.
- Do **not** write to `socket.private` for app-level persistence state. That namespace is reserved (hook table, async ref tracking, pending stream ops). Use a dedicated assign.
- Do **not** introduce a `:persist` hook stage. The six public stages (`:before_command`, `:after_command`, `:handle_async`, `:handle_info`, `:after_to_state`, `:after_serialize`) are stable per BDR-0004; persistence rides on `:after_command`.
