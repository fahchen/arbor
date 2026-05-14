# Getting Started

This tutorial builds a small counter root store, exposes it through a Phoenix
socket, and mounts it from a TypeScript client.

## 1. Add Arbor

In the Phoenix app:

```elixir
def deps do
  [
    {:arbor, "~> 0.1.0"}
  ]
end
```

Run:

```sh
mix deps.get
```

If the application has a TypeScript frontend, add the Arbor compiler so the
generated ambient types stay in sync with the server stores:

```elixir
def project do
  [
    app: :my_app,
    compilers: Mix.compilers() ++ [:arbor_ts]
  ]
end
```

Configure the generated type bundle:

```elixir
config :arbor, :ts_codegen_output_path, "assets/src/generated/arbor.d.ts"
```

## 2. Define A Root Store

Root stores opt in with `use Arbor.Store, root: true`. They may implement
`mount/2`, which receives client mount params before `init/1` runs.

```elixir
defmodule MyAppWeb.Stores.CounterStore do
  use Arbor.Store, root: true

  state do
    field :count, integer()
  end

  command :increment do
    payload :amount, integer()
  end

  @impl Arbor.Store
  def mount(params, socket) do
    {:ok, Arbor.Socket.assign(socket, :count, Map.get(params, "count", 0))}
  end

  @impl Arbor.Store
  def render(socket) do
    %{count: socket.assigns.count}
  end

  @impl Arbor.Store
  def handle_command(:increment, %{"amount" => amount}, socket) do
    {:noreply, Arbor.Socket.update_assign(socket, :count, &(&1 + amount))}
  end
end
```

The `state do` block is both a runtime validation contract and the source for
TypeScript generation. `render/1` returns the Elixir-shaped state; Arbor
serializes it for the wire.

## 3. Declare Mountable Roots

An Arbor socket declares the root stores a client may mount. Application code
implements Arbor callbacks; Phoenix socket and channel behaviours are handled
by the adapter.

```elixir
defmodule MyAppWeb.UserSocket do
  use Arbor.Socket,
    roots: [
      MyAppWeb.Stores.CounterStore
    ]

  @impl Arbor.Socket
  def handle_connect(%{"token" => token}, socket) do
    with {:ok, user} <- MyApp.Auth.verify_user_token(token) do
      {:ok, Arbor.Socket.assign(socket, :current_user, user)}
    else
      _error -> :error
    end
  end

  @impl Arbor.Socket
  def handle_join(_params, socket), do: {:ok, socket}
end
```

`handle_connect/2` runs when Phoenix establishes the socket. Use it for
connection-level authentication and assigns shared by every mounted root.
`handle_join/2` runs once when the Arbor connection joins.

## 4. Wire The Phoenix Endpoint

Register the Arbor socket in the Phoenix endpoint:

```elixir
socket "/socket", MyAppWeb.UserSocket,
  websocket: true,
  longpoll: false
```

If the application needs Phoenix session data in Arbor stores, configure
`connect_info`:

```elixir
socket "/socket", MyAppWeb.UserSocket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: false
```

Stores can then read it with `Arbor.Socket.session(socket)`.

## 5. Mount From TypeScript

Install the client packages:

```sh
pnpm add @arbor/client phoenix
```

Open one connection, then mount one or more declared root stores by module
name and id:

```ts
import { Socket } from "phoenix"
import { connect } from "@arbor/client"

const socket = new Socket("/socket", {
  params: { token: window.userToken },
})

const connection = await connect(socket)

const counter = await connection.mountStore<
  Arbor.Stores,
  "MyAppWeb.Stores.CounterStore"
>({
  module: "MyAppWeb.Stores.CounterStore",
  id: "counter",
  params: { count: 1 },
})

console.log(counter.count)

await counter.dispatchCommand("increment", { amount: 1 })
```

The `id` must be unique within the Arbor connection. A single connection can
mount many root stores as long as each root id is distinct.

## 6. Regenerate Types

When a store's `state do` or `command` declarations change, regenerate the
TypeScript bundle:

```sh
mix compile
```

In CI, check for drift:

```sh
mix compile.arbor_ts --check
```

## Next Steps

- Read `Phoenix Setup` for connection/session details.
- Read `Client and React` for React hooks and root cleanup.
- Read `Client Contract` for the wire and proxy model.
