// Phantom marker shapes mirror the type-only codegen output in
// `priv/codegen/ts/arbor.ts`. Consumers that import this package without
// generating the bundle still need these types to exist so TypeScript can
// resolve the projection helpers below. The generated bundle augments the
// global `Arbor` namespace with the `Arbor.Stores` registry; an empty
// fallback is provided below so the package compiles in isolation.
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Arbor {
    type StoreId = string[]

    type AsyncError =
      | { kind: "error"; value: unknown }
      | { kind: "exit"; value: unknown }

    type AsyncResult<T> =
      | { status: "loading"; data: T | null; error: null }
      | { status: "ok"; data: T; error: null }
      | { status: "failed"; data: T | null; error: AsyncError | unknown }

    interface StoreDef<Module extends string, Shape, Commands> {
      readonly __arbor__module__?: Module
      readonly __arbor__shape__?: Shape
      readonly __arbor__commands__?: Commands
    }

    type StoreField<Module extends string> = {
      readonly __arbor__kind__?: "store"
      readonly __arbor__module__?: Module
    }

    type StreamField<Item> = {
      readonly __arbor__kind__?: "stream"
      readonly __arbor__item__?: Item
    }

    type AsyncField<Value> = {
      readonly __arbor__kind__?: "async"
      readonly __arbor__value__?: Value
    }

    // Generated bundle augments this interface via `declare global`. Without
    // the bundle, the registry is empty and `StoreModule` resolves to `never`.
    // eslint-disable-next-line @typescript-eslint/no-empty-interface
    interface Stores {}
  }
}

export type StoreId = Arbor.StoreId
export type AsyncError = Arbor.AsyncError
export type AsyncResult<T> = Arbor.AsyncResult<T>

// ---------------------------------------------------------------------------
// Module / Def / Shape / Commands accessors
// ---------------------------------------------------------------------------

export type StoreModule = Extract<keyof Arbor.Stores, string>

export type DefOf<M extends StoreModule> = Arbor.Stores[M]

export type ShapeOf<M extends StoreModule> =
  DefOf<M> extends Arbor.StoreDef<infer _Module, infer Shape, infer _Commands>
    ? Shape
    : never

export type CommandsOf<M extends StoreModule> =
  DefOf<M> extends Arbor.StoreDef<infer _Module, infer _Shape, infer Commands>
    ? Commands
    : never

export type CommandName<M extends StoreModule> = keyof CommandsOf<M>

export type CommandPayload<M extends StoreModule, K extends CommandName<M>> =
  CommandsOf<M>[K] extends { payload: infer Payload } ? Payload : never

export type CommandReply<M extends StoreModule, K extends CommandName<M>> =
  CommandsOf<M>[K] extends { reply: infer Reply } ? Reply : unknown

// ---------------------------------------------------------------------------
// Snapshot and proxy projection
// ---------------------------------------------------------------------------

type SnapshotAsyncValue<T> =
  T extends Arbor.StreamField<infer U>
    ? SnapshotValue<U>[]
    : SnapshotValue<T>

export type SnapshotValue<T> =
  T extends Arbor.StoreField<infer M>
    ? M extends StoreModule
      ? StoreSnapshot<M>
      : never
    : T extends Arbor.AsyncField<infer U>
      ? AsyncResult<SnapshotAsyncValue<U>>
      : T extends Arbor.StreamField<infer U>
        ? SnapshotValue<U>[]
        : T extends readonly (infer U)[]
          ? SnapshotValue<U>[]
          : T extends object
            ? { [K in keyof T]: SnapshotValue<T[K]> }
            : T

export type StoreSnapshot<M extends StoreModule> = {
  readonly __arbor_store_id__: StoreId
} & {
  [K in keyof ShapeOf<M>]: SnapshotValue<ShapeOf<M>[K]>
}

export type ProxyValue<T> =
  T extends Arbor.StoreField<infer M>
    ? M extends StoreModule
      ? StoreProxy<M>
      : never
    : T extends Arbor.AsyncField<infer U>
      ? AsyncResult<SnapshotAsyncValue<U>>
      : T extends Arbor.StreamField<infer U>
        ? SnapshotValue<U>[]
        : T extends readonly (infer U)[]
          ? SnapshotValue<U>[]
          : T extends object
            ? { [K in keyof T]: ProxyValue<T[K]> }
            : T

export interface StoreRuntime<M extends StoreModule> {
  readonly __arbor_store_id__: StoreId
  dispatchCommand<K extends CommandName<M>>(
    name: K,
    payload: CommandPayload<M, K>
  ): Promise<CommandReply<M, K>>
  subscribe(listener: () => void): () => void
  snapshot(): StoreSnapshot<M>
}

export type StoreProxy<M extends StoreModule> = StoreRuntime<M> & {
  [K in keyof ShapeOf<M>]: ProxyValue<ShapeOf<M>[K]>
}

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

export type StreamEntry<T> = {
  itemKey: string
  item: T
}

export type JsonPatchOp =
  | { op: "add"; path: string; value: unknown }
  | { op: "remove"; path: string }
  | { op: "replace"; path: string; value: unknown }

export type StreamOp =
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

export type PatchEnvelope = {
  type: "patch"
  base_version: number
  version: number
  ops: JsonPatchOp[]
  stream_ops: StreamOp[]
}

export type WireAsyncError =
  | { kind: "error"; value: unknown }
  | { kind: "exit"; value: unknown }

export type WireAsyncResult<T = unknown> =
  | { status: "loading"; result: T | null; reason: null }
  | { status: "ok"; result: T; reason: null }
  | { status: "failed"; result: T | null; reason: WireAsyncError | unknown }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export const STORE_ID_KEY = "__arbor_store_id__" as const

export function storeIdKey(storeId: StoreId): string {
  return JSON.stringify(storeId)
}

const STREAM_KEY_SEP = "\0"

export function streamStoreKey(storeId: StoreId, streamName: string): string {
  return `${storeIdKey(storeId)}${STREAM_KEY_SEP}${streamName}`
}

export function streamStoreKeyPrefix(storeId: StoreId): string {
  return `${storeIdKey(storeId)}${STREAM_KEY_SEP}`
}

export function streamFieldNameFromKey(key: string): string {
  const parts = key.split(STREAM_KEY_SEP)
  return parts[1] ?? ""
}

export function storeKeyFromStreamStoreKey(key: string): string {
  const parts = key.split(STREAM_KEY_SEP)
  return parts[0] ?? key
}
