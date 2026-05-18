# Musubi client contract

This document summarizes the current client-facing Musubi contract. The
authoritative runtime behavior still lives in `spec/` and the BDR records;
this file describes how the generated TypeScript surface and client packages
fit that contract.

## Status

The settled direction is:

- clients open one Musubi connection, then mount declared roots by `{module, id}`
- one physical `Phoenix.Socket` carries many logical Musubi roots
- the server owns the store tree and sends patch envelopes
- the TypeScript client materializes the tree, streams, async values, and
  store proxies
- generated TypeScript is type-only; it does not emit runtime descriptors,
  registries, store objects, or proxy implementations
- generated marker internals are symbol-branded type information, never wire
  data

Runtime keys are deliberately stable. In particular, keep
`__musubi_store_id__` as the reserved field on rendered store nodes.

## Public Client Shape

Applications create one Phoenix socket, open one Musubi connection, and mount
declared roots through that connection. The generated `Musubi.Stores`
registry type is bound to the API exactly once — via the `R` generic on
`connect<R>(socket)`, or via `createMusubi<R>()` in `@musubi/react` —
and the `module` string literal then drives type inference for every
later `mountStore` call. `mountStore` returns a `{ store, unmount }`
pair.

```ts
const phx = new Phoenix.Socket("/socket", {
  params: { token: window.userToken },
})

const connection = await connect<Musubi.Stores>(phx)

const { store: cart, unmount } = await connection.mountStore({
  module: "MyApp.Stores.CartPageStore",
  id: "cart:page",
  params: { cart_id: "cart:page" },
})

cart.title
cart.header.title
cart.lines.map((line) => line.name)

const reply = await cart.dispatchCommand("checkout", {})

await unmount()
```

The backend socket module declares the root-store allowlist and implements only
Musubi callbacks. Phoenix socket and channel behaviours are adapter details.

```elixir
defmodule MyAppWeb.UserSocket do
  use Musubi.Socket,
    roots: [
      MyApp.Stores.CartPageStore,
      MyApp.Stores.DashboardStore
    ]

  @impl Musubi.Socket
  def handle_connect(%{"token" => token}, socket) do
    {:ok, Musubi.Socket.assign(socket, :token, token)}
  end

  @impl Musubi.Socket
  def handle_join(_params, socket), do: {:ok, socket}
end
```

Public rules:

- callers open one connection and mount roots by module name plus root id
- callers do not pass generated runtime values
- callers do not decode patches, streams, or async wire values manually
- callers may explicitly unmount a mounted root by awaiting the `unmount`
  closure returned from `mountStore`
- `connection.disconnect()` returns `Promise<void>`
- child stores are exposed as nested proxies
- streams are exposed as materialized arrays
- async values are exposed as normalized `AsyncResult<T>`

## Identity

Musubi connection identity is the Phoenix channel topic:

```ts
type Connect = {
  topic?: string
}
```

The default topic is `"musubi:connection"`. The client sends an empty channel join
payload for the connection. Auth and transport-level data should come from
Phoenix socket params/connect_info; root business params belong to `mountStore`.

Root mount identity is:

```ts
type MountStore = {
  module: string
  id: string
  params?: Record<string, unknown>
}
```

The `module` string must match a root store module declared by the backend
connection. The `id` must be explicit and unique within that connection.

Mounted store identity inside a connected tree is:

```ts
type StoreId = string[]
```

Rules:

- the root store id is `[]`
- child store ids are authored by the server
- the client echoes server-provided ids verbatim when dispatching commands
- the client never constructs or parses store ids

Every rendered store node carries:

```ts
type StoreNodeRef = {
  __musubi_store_id__: StoreId
}
```

## Wire Contract

Mounting a declared root sends:

```ts
type MountMessage = {
  module: string
  id: string
  params: Record<string, unknown>
}
```

Commands target mounted stores by `root_id` plus `store_id`:

```ts
type CommandMessage = {
  root_id: string
  store_id: StoreId
  name: string
  payload: Record<string, unknown>
}
```

Patch pushes use JSON Patch for ordinary state and `stream_ops` for stream
materialization:

```ts
type JsonPatchOp =
  | { op: "add"; path: string; value: unknown }
  | { op: "remove"; path: string }
  | { op: "replace"; path: string; value: unknown }

type StreamOp =
  | { op: "reset"; stream: string; ref: string; store_id: StoreId }
  | {
      op: "insert"
      stream: string
      ref: string
      store_id: StoreId
      item_key: string
      at: number
      item: unknown
      limit: number | null
    }
  | {
      op: "delete"
      stream: string
      ref: string
      store_id: StoreId
      item_key: string
    }

type PatchEnvelope = {
  type: "patch"
  base_version: number
  version: number
  ops: JsonPatchOp[]
  stream_ops: StreamOp[]
}

type WireStreamMarker = {
  __musubi_stream__: string
}

type ConnectionPatchEnvelope = PatchEnvelope & {
  root_id: string
}
```

Envelope rules:

- the initial envelope carries `base_version: 0` and `version: 1`
- each later envelope must apply to the client's current version
- idle render cycles emit no envelope
- reconnect creates a fresh page runtime and fresh version sequence
- in connection transport, every patch envelope includes `root_id`; the client
  applies it only to the matching mounted root runtime
- stream placement paths contain `WireStreamMarker` objects in `ops`
- stream contents move through `stream_ops`

See `Musubi.Stream` for declaration, render placement, and validation
rules.

## Async Values

The wire shape mirrors `Musubi.AsyncResult` serialization:

```ts
type WireAsyncError =
  | { kind: "error"; value: unknown }
  | { kind: "exit"; value: unknown }

type WireAsyncResult<T = unknown> =
  | { status: "loading"; result: T | null; reason: null }
  | { status: "ok"; result: T; reason: null }
  | { status: "failed"; result: T | null; reason: WireAsyncError | unknown }
```

The public client normalizes this to:

```ts
type AsyncError =
  | { kind: "error"; value: unknown }
  | { kind: "exit"; value: unknown }

type AsyncResult<T> =
  | { status: "loading"; data: T | null; error: null }
  | { status: "ok"; data: T; error: null }
  | { status: "failed"; data: T | null; error: AsyncError | unknown }
```

Normalization rules:

- `result` becomes `data`
- `reason` becomes `error`
- `AsyncResult.of(T)` projects to `AsyncResult<T>`
- `AsyncResult.of(stream(T))` projects to `AsyncResult<T[]>`; on the wire the
  async `result` is the stream marker, and item content still arrives through
  `stream_ops`

## Generated TypeScript

`mix compile.musubi_ts` emits an ambient `.d.ts` bundle. It owns the generated
`Musubi.Stores` interface and the marker types used by `@musubi/client`.

```ts
declare namespace Musubi {
  type StoreId = string[]

  const Type: unique symbol

  interface StoreDef<Module extends string, Shape, Commands> {
    readonly [Type]: {
      module: Module
      shape: Shape
      commands: Commands
    }
  }

  type StoreField<Module extends string> = {
    readonly [Type]: { kind: "store"; module: Module }
  }

  type StreamField<Item> = {
    readonly [Type]: { kind: "stream"; item: Item }
  }

  type AsyncField<Value> = {
    readonly [Type]: { kind: "async"; value: Value }
  }

  interface Stores {
    "MyApp.Stores.CartPageStore": StoreDef<
      "MyApp.Stores.CartPageStore",
      {
        title: string
        header: StoreField<"MyApp.Stores.HeaderStore">
        lines: StreamField<MyApp.CartLine>
        profile: AsyncField<MyApp.Profile>
      },
      {
        checkout: {
          payload: {}
          reply: { order_id: string } | { error: string }
        }
      }
    >
  }
}
```

Marker rules:

- markers are type-only
- marker properties never appear on the wire
- the runtime never reads marker properties
- symbol branding prevents ordinary user objects from matching Musubi marker
  types by accident

## Client Projection

The client package exports an empty augmentable `Registry` interface and
derives public proxy and snapshot types from it. User-facing helpers
take the module key first and default the registry to `Registry`; the
registry itself is bound for the connection by `connect<R>(socket)` or
`createMusubi<R>()`, not threaded through every call.

```ts
// Empty by default; users pass their generated `Musubi.Stores` as `R`.
interface Registry {}

type StoreModule<R = Registry> = Extract<keyof R, string>
type DefOf<M extends StoreModule<R>, R = Registry> = R[M & keyof R]

type StoreSnapshot<M extends StoreModule<R>, R = Registry> = {
  readonly __musubi_store_id__: StoreId
} & {
  [K in keyof ShapeOf<M, R>]: SnapshotValue<ShapeOf<M, R>[K], R>
}

interface StoreRuntime<M extends StoreModule<R>, R = Registry> {
  readonly __musubi_store_id__: StoreId
  dispatchCommand<K extends CommandName<M, R>>(
    name: K,
    payload: CommandPayload<M, K, R>
  ): Promise<CommandReply<M, K, R>>
  subscribe(listener: () => void): () => void
  snapshot(): StoreSnapshot<M, R>
}

type StoreProxy<M extends StoreModule<R>, R = Registry> =
  StoreRuntime<M, R> & {
    [K in keyof ShapeOf<M, R>]: ProxyValue<ShapeOf<M, R>[K], R>
  }
```

`SnapshotValue<T, R = Registry>` and `ProxyValue<T, R = Registry>` keep
`T` first because `T` is a projected wire type, not a module key.

Reserved runtime member names on every store proxy:

- `__musubi_store_id__`
- `dispatchCommand`
- `subscribe`
- `snapshot`

## Runtime Materialization

For each connected root, the TypeScript runtime maintains:

- the latest accepted version
- the patched wire tree
- a `store_id -> node` index
- a `(store_id, stream_name) -> materialized_list` table
- a `store_id -> proxy` cache

Property resolution on a proxy follows the live wire shape:

1. reserved runtime members return runtime implementations
2. wire values carrying `__musubi_store_id__` return cached nested proxies
3. wire values carrying `__musubi_stream__` return materialized arrays
4. async values return normalized `AsyncResult<T>`
5. async streams return normalized `AsyncResult<T[]>`
6. plain objects recurse through the same resolution rules
7. plain fields return their wire value

Generated marker types only drive TypeScript inference. Runtime behavior is
driven by the wire tree, stream tables, and proxy cache.

## Separation Of Concerns

Server/codegen owns:

- the declared store shape
- command payload and reply types
- type-only markers for store, stream, and async fields
- the generated `Musubi.Stores` registry

Client runtime owns:

- opening Phoenix Channel connections
- applying patch envelopes
- materializing streams
- normalizing async wire values
- constructing and caching proxies
- dispatching commands with server-provided `store_id` values
