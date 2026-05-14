# Arbor

Arbor is a server-authoritative runtime for Elixir/Phoenix applications. A
Phoenix socket owns one Arbor connection, and that connection can mount many
declared root stores. Each root store runs in its own page-scoped process,
renders typed state on the server, and streams RFC 6902 JSON Patch envelopes to
the TypeScript client.

Arbor is useful when you want LiveView-style server authority, but your client
is a TypeScript or React application that owns rendering.

## Current Status

Arbor is pre-1.0. The public model is intentionally narrow:

- backend modules declare stores with `use Arbor.Store`
- socket modules declare mountable roots with `use Arbor.Socket, roots: [...]`
- clients call `connect(socket)` once, then mount root stores by `{module, id}`
- child stores are created by server render output and are not mounted directly
- commands, streams, async values, and patch application are handled by the
  runtime packages

Breaking changes are still possible before 1.0.

## Installation

Add Arbor to your Phoenix application:

```elixir
def deps do
  [
    {:arbor, "~> 0.1.0"}
  ]
end
```

Arbor uses Phoenix Channel transport internally and supports Phoenix
`>= 1.5.3 and < 2.0.0`.

For generated TypeScript types, add Arbor's compiler to the consumer app:

```elixir
def project do
  [
    app: :my_app,
    compilers: Mix.compilers() ++ [:arbor_ts]
  ]
end
```

Configure the generated `.d.ts` output path:

```elixir
config :arbor, :ts_codegen_output_path, "assets/src/generated/arbor.d.ts"
```

Install the client packages in the frontend project:

```sh
pnpm add @arbor/client @arbor/react phoenix
```

## Minimal Example

Declare a root store:

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
  def render(socket), do: %{count: socket.assigns.count}

  @impl Arbor.Store
  def handle_command(:increment, %{"amount" => amount}, socket) do
    {:noreply, Arbor.Socket.update_assign(socket, :count, &(&1 + amount))}
  end
end
```

Expose it through an Arbor socket:

```elixir
defmodule MyAppWeb.UserSocket do
  use Arbor.Socket,
    roots: [
      MyAppWeb.Stores.CounterStore
    ]

  @impl Arbor.Socket
  def handle_connect(_params, socket), do: {:ok, socket}

  @impl Arbor.Socket
  def handle_join(_params, socket), do: {:ok, socket}
end
```

Mount the root from TypeScript:

```ts
import { Socket } from "phoenix"
import { connect } from "@arbor/client"

const socket = new Socket("/socket", { params: { token: window.userToken } })
const connection = await connect(socket)

const counter = await connection.mountStore<
  Arbor.Stores,
  "MyAppWeb.Stores.CounterStore"
>({
  module: "MyAppWeb.Stores.CounterStore",
  id: "counter",
  params: { count: 1 },
})

await counter.dispatchCommand("increment", { amount: 1 })
```

## Documentation

- [Getting Started](guides/getting-started.md)
- [Phoenix Setup](guides/phoenix-setup.md)
- [Client and React](guides/client-and-react.md)
- [Client Contract](docs/client-contract.md)
- [Persistence Pattern](docs/persistence-pattern.md)

Build local ExDoc output with:

```sh
mix deps.get
mix docs
```

## Examples

The repository includes standalone Phoenix examples under `examples/`:

- `examples/cart_page` - cart UI with nested stores and persistence hooks
- `examples/chat_room` - PubSub-backed chat room
- `examples/poll_app` - multi-root polling application with streams and async

Each example depends on Arbor with `path: "../.."`.
