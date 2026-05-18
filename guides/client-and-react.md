# Client And React

The TypeScript packages mirror the backend connection model:

- `@musubi/client` owns Phoenix channel interaction, patch application, streams,
  async result normalization, command dispatch, and store proxies.
- `@musubi/react` provides React context and hooks over an `MusubiConnection`.

## Plain TypeScript

Create one Phoenix socket, then call `connect<Musubi.Stores>(socket)` once.
The generic argument binds the generated registry for the connection;
every later `mountStore` call infers the store type from the `module`
string literal alone.

```ts
import { Socket } from "phoenix"
import { connect } from "@musubi/client"

const socket = new Socket("/socket", {
  params: { token: window.userToken },
})

const connection = await connect<Musubi.Stores>(socket)
```

Mount a declared root store. `mountStore` returns a
`{ store, unmount }` pair:

```ts
const { store: dashboard, unmount } = await connection.mountStore({
  module: "MyApp.Stores.DashboardStore",
  id: "dashboard",
})
```

Read state through the proxy:

```ts
dashboard.header.title
dashboard.polls.map((poll) => poll.title)
```

Dispatch a declared command:

```ts
await dashboard.dispatchCommand("refresh", {})
```

Unmount when the root is no longer needed by calling the `unmount`
closure returned from `mountStore`:

```ts
await unmount()
```

## React: createMusubi

`@musubi/react` exports a `createMusubi<R>()` factory. Call it exactly
once per app, alongside the Phoenix socket. The factory closes over the
generated registry `R` and returns a `connect`, `MusubiProvider`, and
hook set whose closures all know `R` without any further generic
threading:

```ts
// src/musubi.ts
import { Socket } from "phoenix"
import { createMusubi } from "@musubi/react"

export const socket = new Socket("/socket", {
  params: { token: window.userToken },
})

export const {
  connect,
  MusubiProvider,
  useMusubiConnection,
  useMusubiRoot,
  useMusubiSnapshot,
  useMusubiCommand,
} = createMusubi<Musubi.Stores>()
```

Open the connection once at app boot and pass it to `MusubiProvider`:

```tsx
// src/main.tsx
import { createRoot } from "react-dom/client"
import App from "./App"
import { connect, MusubiProvider, socket } from "./musubi"

const root = createRoot(document.getElementById("root")!)
const connection = await connect(socket)

root.render(
  <MusubiProvider connection={connection}>
    <App />
  </MusubiProvider>,
)
```

## Mount Roots In React

Use the factory's `useMusubiRoot` to mount a declared root under the
nearest provider. The `module` literal alone drives inference:

```tsx
import { useMusubiRoot } from "./musubi"

export function Dashboard() {
  const root = useMusubiRoot({
    module: "MyApp.Stores.DashboardStore",
    id: "dashboard",
  })

  if (root.status === "loading") {
    return null
  }

  if (root.status === "error") {
    return <p>{root.error.message}</p>
  }

  return <DashboardContent store={root.store} />
}
```

`useMusubiRoot` unmounts the root when the component unmounts by default. Pass
`unmountOnCleanup: false` when a mounted root should outlive the component.

## Subscribe To Snapshots

`useMusubiSnapshot` subscribes to proxy updates and returns an immutable
snapshot:

```tsx
import type { StoreProxy } from "@musubi/react"
import { useMusubiCommand, useMusubiSnapshot } from "./musubi"

type Store<M extends keyof Musubi.Stores & string> = StoreProxy<M, Musubi.Stores>

function DashboardContent({ store }: { store: Store<"MyApp.Stores.DashboardStore"> }) {
  const title = useMusubiSnapshot(store, (snapshot) => snapshot.header.title)
  const refresh = useMusubiCommand(store, "refresh")

  return (
    <button onClick={() => void refresh({})}>
      {title}
    </button>
  )
}
```

Use selectors to keep React renders focused. A component that selects
`snapshot.header.title` does not need to re-render for unrelated store fields.

## Target Child Stores

Every store in the tree — not just the root — can declare commands and accept
them through its own proxy. Children show up as nested proxies on the root,
reachable by field access for single children and by array index for list
children. `useMusubiCommand` works on any proxy.

### Declaring a command on a child store

The Elixir DSL is identical for root and child stores:

```elixir
defmodule MyApp.Stores.CartLineStore do
  use Musubi.Store

  attr(:line, map(), required: true)
  attr(:on_qty_change, (String.t(), integer() -> :ok), required: true)

  state do
    field(:qty, integer())
  end

  command :inc_qty do
    reply(%{qty: integer()})
  end

  @impl Musubi.Store
  def handle_command(:inc_qty, _payload, socket) do
    next_qty = socket.assigns.qty + 1
    socket = assign(socket, :qty, next_qty)
    :ok = socket.assigns.on_qty_change.(socket.assigns.id, next_qty)
    {:reply, %{"qty" => next_qty}, socket}
  end
end
```

### Reaching the child proxy from React

Field access returns a single child proxy; iterating a list field returns one
proxy per element. Each carries its own `dispatchCommand`:

```tsx
function HeaderRename({ root }: { root: Store<"MyApp.Stores.CartPageStore"> }) {
  const setName = useMusubiCommand(root.header, "rename")
  return <button onClick={() => void setName({ name: "Ada" })}>Rename</button>
}

function CartLine({ lineProxy }: { lineProxy: Store<"MyApp.Stores.CartLineStore"> }) {
  const line = useMusubiSnapshot(lineProxy)
  const inc = useMusubiCommand(lineProxy, "inc_qty")
  return <button onClick={() => void inc({})}>{line.qty}</button>
}

function CartLines({ root }: { root: Store<"MyApp.Stores.CartPageStore"> }) {
  return (
    <ul>
      {root.cart.lines.map((lineProxy) => (
        <CartLine key={lineProxy.__musubi_store_id__.join("/")} lineProxy={lineProxy} />
      ))}
    </ul>
  )
}
```

The wire payload carries the full `store_id` path, so the page server routes
`inc_qty` directly to the addressed `CartLineStore` instance. Authorization
and audit hooks attached to ancestor stores fire as part of that chain.

### Notify the parent from a child command

Children don't write to a parent's `socket.assigns` directly. The conventional
pattern is a function-valued attr (BDR-0010) — the parent supplies a closure
in its `render/1`, and the child invokes it after mutating its own state:

```elixir
# Parent
def render(socket) do
  %{
    lines:
      for line <- socket.assigns.lines do
        child(CartLineStore,
          id: line.id,
          line: line,
          on_qty_change: socket.assigns.on_qty_change   # stable closure built in mount/1
        )
      end
  }
end
```

What the closure does is up to the parent — write through a shared
`Persistence` snapshot whose PubSub broadcast re-flows the new state through
the root, `send(self(), {:msg, ...})` so the root's `handle_info/2` picks it
up, or hit any other application boundary. Building the closure once in
`mount/1` (rather than per-render) keeps the function reference stable across
re-renders so child memoization via `__changed__` (BDR-0013) still applies.

See `examples/cart_page` for a runnable demo of the full child-command +
callback-attr round-trip.

## Async Results And Streams

The client normalizes `Musubi.AsyncResult` values to:

```ts
type AsyncResult<T> =
  | { status: "loading"; data: T | null; error: null }
  | { status: "ok"; data: T; error: null }
  | { status: "failed"; data: T | null; error: unknown }
```

Streams are materialized as arrays. The server sends stream ops; the client
owns list materialization and limit trimming.
