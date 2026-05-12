// The generated codegen bundle (`priv/codegen/ts/arbor.ts`) is the canonical
// declaration site for the `Arbor.*` global namespace — it ships the phantom
// marker types (`StoreId`, `AsyncResult`, `StoreDef`, `StoreField`,
// `StreamField`, `AsyncField`) plus the `Stores` registry entries.
//
// This package only seeds an empty `Arbor.Stores` registry so the client
// compiles in isolation; the registry is augmented (via interface merging)
// once a consumer imports the generated bundle. The projection helpers below
// match marker shapes structurally on `__arbor__kind__` so they don't depend
// on the generated marker type names being in scope.
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Arbor {
    // eslint-disable-next-line @typescript-eslint/no-empty-interface
    interface Stores {}
  }
}

// ---------------------------------------------------------------------------
// Public runtime types
// ---------------------------------------------------------------------------

export type StoreId = string[]

export type AsyncError =
  | { kind: "error"; value: unknown }
  | { kind: "exit"; value: unknown }

export type AsyncResult<T> =
  | { status: "loading"; data: T | null; error: null }
  | { status: "ok"; data: T; error: null }
  | { status: "failed"; data: T | null; error: AsyncError | unknown }

// ---------------------------------------------------------------------------
// Module / Def / Shape / Commands accessors
// ---------------------------------------------------------------------------

export type StoreModule = Extract<keyof Arbor.Stores, string>

export type DefOf<M extends StoreModule> = Arbor.Stores[M]

export type ShapeOf<M extends StoreModule> =
  DefOf<M> extends { readonly __arbor__shape__?: infer Shape }
    ? NonNullable<Shape>
    : never

export type CommandsOf<M extends StoreModule> =
  DefOf<M> extends { readonly __arbor__commands__?: infer Commands }
    ? NonNullable<Commands>
    : never

export type CommandName<M extends StoreModule> = keyof CommandsOf<M>

export type CommandPayload<M extends StoreModule, K extends CommandName<M>> =
  CommandsOf<M>[K] extends { payload: infer Payload } ? Payload : never

export type CommandReply<M extends StoreModule, K extends CommandName<M>> =
  CommandsOf<M>[K] extends { reply: infer Reply } ? Reply : unknown

// ---------------------------------------------------------------------------
// Snapshot and proxy projection (structural marker matching)
// ---------------------------------------------------------------------------

type IsStoreField<T> = T extends { readonly __arbor__kind__?: "store" } ? true : false
type IsStreamField<T> = T extends { readonly __arbor__kind__?: "stream" } ? true : false
type IsAsyncField<T> = T extends { readonly __arbor__kind__?: "async" } ? true : false

type StoreFieldModule<T> =
  T extends { readonly __arbor__module__?: infer M } ? NonNullable<M> : never
type StreamFieldItem<T> =
  T extends { readonly __arbor__item__?: infer Item } ? NonNullable<Item> : never
type AsyncFieldValue<T> =
  T extends { readonly __arbor__value__?: infer Value } ? NonNullable<Value> : never

type SnapshotAsyncValue<T> =
  IsStreamField<T> extends true
    ? SnapshotValue<StreamFieldItem<T>>[]
    : SnapshotValue<T>

export type SnapshotValue<T> =
  IsStoreField<T> extends true
    ? StoreFieldModule<T> extends infer M
      ? M extends StoreModule
        ? StoreSnapshot<M>
        : never
      : never
    : IsAsyncField<T> extends true
      ? AsyncResult<SnapshotAsyncValue<AsyncFieldValue<T>>>
      : IsStreamField<T> extends true
        ? SnapshotValue<StreamFieldItem<T>>[]
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
  IsStoreField<T> extends true
    ? StoreFieldModule<T> extends infer M
      ? M extends StoreModule
        ? StoreProxy<M>
        : never
      : never
    : IsAsyncField<T> extends true
      ? AsyncResult<SnapshotAsyncValue<AsyncFieldValue<T>>>
      : IsStreamField<T> extends true
        ? SnapshotValue<StreamFieldItem<T>>[]
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
