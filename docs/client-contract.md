# Arbor client contract

This document summarizes the current client-facing Arbor contract. The
authoritative runtime behavior still lives in `spec/` and the BDR records;
this file describes how the generated TypeScript surface and client packages
fit that contract.

## Status

The settled direction is:

- roots connect by `{module, id}`
- one physical `Phoenix.Socket` can carry many logical Arbor roots
- the server owns the store tree and sends patch envelopes
- the TypeScript client materializes the tree, streams, async values, and
  store proxies
- generated TypeScript is type-only; it does not emit runtime descriptors,
  registries, store objects, or proxy implementations
- generated marker internals are symbol-branded type information, never wire
  data

Runtime keys are deliberately stable. In particular, keep
`__arbor_store_id__` as the reserved field on rendered store nodes.

## Public Client Shape

Applications create one Phoenix socket and connect Arbor roots through it.
The generated `Arbor.Stores` registry type is threaded into the client API;
the `module` string literal then selects the concrete store type.

```ts
const phx = new Phoenix.Socket("/socket", {
  params: { token: window.userToken },
})

const cart = await connectStore<Arbor.Stores>(phx, {
  module: "MyApp.Stores.CartPageStore",
  id: "cart:page",
})

cart.title
cart.header.title
cart.lines.map((line) => line.name)

const reply = await cart.dispatchCommand("checkout", {})
```

Public rules:

- callers connect a root by module name plus root id
- callers do not pass generated runtime values
- callers do not decode patches, streams, or async wire values manually
- child stores are exposed as nested proxies
- streams are exposed as materialized arrays
- async values are exposed as normalized `AsyncResult<T>`

## Identity

Root connection identity is:

```ts
type RootConnect = {
  module: string
  id: string
  params?: Record<string, unknown>
}
```

The transport may derive an internal channel topic, but `topic` is not public
client API.

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
  __arbor_store_id__: StoreId
}
```

## Wire Contract

Commands target mounted stores by `store_id`:

```ts
type CommandMessage = {
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
```

Envelope rules:

- the initial envelope carries `base_version: 0` and `version: 1`
- each later envelope must apply to the client's current version
- idle render cycles emit no envelope
- reconnect creates a fresh page runtime and fresh version sequence
- stream-typed paths never appear in `ops`
- stream contents move through `stream_ops`

## Async Values

The wire shape mirrors `Arbor.AsyncResult` serialization:

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
- `AsyncResult.of(stream(T))` projects to `AsyncResult<T[]>`

## Generated TypeScript

`mix compile.arbor_ts` emits an ambient `.d.ts` bundle. It owns the generated
`Arbor.Stores` interface and the marker types used by `@arbor/client`.

```ts
declare namespace Arbor {
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
- symbol branding prevents ordinary user objects from matching Arbor marker
  types by accident

## Client Projection

The client package derives public proxy and snapshot types from the generated
registry.

```ts
type StoreModule<R> = Extract<keyof R, string>
type DefOf<R, M extends StoreModule<R>> = R[M & keyof R]

type StoreSnapshot<R, M extends StoreModule<R>> = {
  readonly __arbor_store_id__: StoreId
} & {
  [K in keyof ShapeOf<R, M>]: SnapshotValue<R, ShapeOf<R, M>[K]>
}

interface StoreRuntime<R, M extends StoreModule<R>> {
  readonly __arbor_store_id__: StoreId
  dispatchCommand<K extends CommandName<R, M>>(
    name: K,
    payload: CommandPayload<R, M, K>
  ): Promise<CommandReply<R, M, K>>
  subscribe(listener: () => void): () => void
  snapshot(): StoreSnapshot<R, M>
}

type StoreProxy<R, M extends StoreModule<R>> =
  StoreRuntime<R, M> & {
    [K in keyof ShapeOf<R, M>]: ProxyValue<R, ShapeOf<R, M>[K]>
  }
```

Reserved runtime member names on every store proxy:

- `__arbor_store_id__`
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
2. wire values carrying `__arbor_store_id__` return cached nested proxies
3. stream fields return materialized arrays
4. async values return normalized `AsyncResult<T>`
5. async streams return normalized `AsyncResult<T[]>`
6. plain fields return their wire value

Generated marker types only drive TypeScript inference. Runtime behavior is
driven by the wire tree, stream tables, and proxy cache.

## Separation Of Concerns

Server/codegen owns:

- the declared store shape
- command payload and reply types
- type-only markers for store, stream, and async fields
- the generated `Arbor.Stores` registry

Client runtime owns:

- opening Phoenix Channel connections
- applying patch envelopes
- materializing streams
- normalizing async wire values
- constructing and caching proxies
- dispatching commands with server-provided `store_id` values
