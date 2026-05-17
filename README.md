# Musubi

Musubi is a server-authoritative runtime for Elixir/Phoenix applications. A
Phoenix socket owns one Musubi connection, and that connection can mount many
declared root stores. Each root store runs in its own page-scoped process,
renders typed state on the server, and streams RFC 6902 JSON Patch envelopes to
the TypeScript client.

Musubi is useful when you want LiveView-style server authority, but your client
is a TypeScript or React application that owns rendering.

## Current Status

Musubi is pre-1.0. The public model is intentionally narrow:

- backend modules declare stores with `use Musubi.Store`
- socket modules declare mountable roots with `use Musubi.Socket, roots: [...]`
- clients call `connect(socket)` once, then mount root stores by `{module, id}`
- child stores are created by server render output and are not mounted directly
- commands, streams, async values, and patch application are handled by the
  runtime packages

Breaking changes are still possible before 1.0.

## Installation

Add Musubi to your Phoenix application:

```elixir
def deps do
  [
    {:musubi, "~> 0.1.0"}
  ]
end
```

For generated TypeScript types, add Musubi's compiler to the consumer app:

```elixir
def project do
  [
    app: :my_app,
    compilers: Mix.compilers() ++ [:musubi_ts]
  ]
end
```

Configure the generated `.d.ts` output path:

```elixir
config :musubi, :ts_codegen_output_path, "assets/src/generated/musubi.d.ts"
```

The JavaScript client packages ship inside the Musubi Hex package under
`deps/musubi/packages/`. Reference them by local path from the frontend
project's `package.json` (adjust the relative path so it points at
`deps/musubi/packages/<name>` from the JS app root):

```json
{
  "dependencies": {
    "@musubi/client": "file:../deps/musubi/packages/client",
    "@musubi/react": "file:../deps/musubi/packages/react",
    "phoenix": "file:../deps/phoenix"
  }
}
```

Then run the package manager once after `mix deps.get`:

```sh
pnpm install   # or npm install / yarn install
```

`@musubi/client` and `@musubi/react` ship TypeScript source directly; the
consumer bundler (Vite, Phoenix esbuild) transpiles on demand — no build
step required.

## Minimal Example

Declare a root store:

```elixir
defmodule MyAppWeb.Stores.CounterStore do
  use Musubi.Store, root: true

  state do
    field :count, integer()
  end

  command :increment do
    payload :amount, integer()
  end

  @impl Musubi.Store
  def mount(params, socket) do
    {:ok, assign(socket, :count, Map.get(params, "count", 0))}
  end

  @impl Musubi.Store
  def render(socket), do: %{count: socket.assigns.count}

  @impl Musubi.Store
  def handle_command(:increment, %{"amount" => amount}, socket) do
    {:noreply, update(socket, :count, &(&1 + amount))}
  end
end
```

Expose it through a Musubi socket:

```elixir
defmodule MyAppWeb.UserSocket do
  use Musubi.Socket,
    roots: [
      MyAppWeb.Stores.CounterStore
    ]

  @impl Musubi.Socket
  def handle_connect(_params, socket), do: {:ok, socket}

  @impl Musubi.Socket
  def handle_join(_params, socket), do: {:ok, socket}
end
```

Mount the root from TypeScript:

```ts
import { Socket } from "phoenix"
import { connect } from "@musubi/client"

const socket = new Socket("/socket", { params: { token: window.userToken } })
const connection = await connect(socket)

const counter = await connection.mountStore<
  Musubi.Stores,
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

Each example depends on Musubi with `path: "../.."`.
