# Client And React

The TypeScript packages mirror the backend connection model:

- `@arbor/client` owns Phoenix channel interaction, patch application, streams,
  async result normalization, command dispatch, and store proxies.
- `@arbor/react` provides React context and hooks over an `ArborConnection`.

## Plain TypeScript

Create one Phoenix socket and one Arbor connection:

```ts
import { Socket } from "phoenix"
import { connect } from "@arbor/client"

const socket = new Socket("/socket", {
  params: { token: window.userToken },
})

const connection = await connect(socket)
```

Mount a declared root store:

```ts
const dashboard = await connection.mountStore<
  Arbor.Stores,
  "MyApp.Stores.DashboardStore"
>({
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

Unmount when the root is no longer needed:

```ts
await connection.unmountStore("dashboard")
```

## React Provider

Create the connection once and pass it to `ArborProvider`:

```tsx
import { Socket } from "phoenix"
import { connect, type ArborConnection } from "@arbor/client"
import { ArborProvider } from "@arbor/react"
import { useEffect, useState } from "react"

export function App() {
  const [connection, setConnection] = useState<ArborConnection | null>(null)

  useEffect(() => {
    const socket = new Socket("/socket", {
      params: { token: window.userToken },
    })

    let cancelled = false
    let current: ArborConnection | null = null

    connect(socket).then((next) => {
      current = next

      if (!cancelled) {
        setConnection(next)
      }
    })

    return () => {
      cancelled = true
      current?.disconnect()
    }
  }, [])

  if (!connection) {
    return null
  }

  return (
    <ArborProvider connection={connection}>
      <Dashboard />
    </ArborProvider>
  )
}
```

## Mount Roots In React

Use `useArborRoot` to mount a declared root under the nearest provider:

```tsx
import { useArborCommand, useArborRoot, useArborSnapshot } from "@arbor/react"
import type { StoreProxy } from "@arbor/client"

type Registry = Arbor.Stores
type DashboardModule = "MyApp.Stores.DashboardStore"

export function Dashboard() {
  const root = useArborRoot<Registry, DashboardModule>({
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

`useArborRoot` unmounts the root when the component unmounts by default. Pass
`unmountOnCleanup: false` when a mounted root should outlive the component.

## Subscribe To Snapshots

`useArborSnapshot` subscribes to proxy updates and returns an immutable
snapshot:

```tsx
function DashboardContent({ store }: { store: StoreProxy<Registry, DashboardModule> }) {
  const title = useArborSnapshot(store, (snapshot) => snapshot.header.title)
  const refresh = useArborCommand(store, "refresh")

  return (
    <button onClick={() => void refresh({})}>
      {title}
    </button>
  )
}
```

Use selectors to keep React renders focused. A component that selects
`snapshot.header.title` does not need to re-render for unrelated store fields.

## Async Results And Streams

The client normalizes `Arbor.AsyncResult` values to:

```ts
type AsyncResult<T> =
  | { status: "loading"; data: T | null; error: null }
  | { status: "ok"; data: T; error: null }
  | { status: "failed"; data: T | null; error: unknown }
```

Streams are materialized as arrays. The server sends stream ops; the client
owns list materialization and limit trimming.
