// Public types for `@arbor/client`. Consumers thread their generated
// `<Root>.Stores` type (emitted by `mix compile.arbor_ts` into an ambient
// `.d.ts` bundle) through `connection.mountStore` and friends as the `Registry`
// generic — every other helper (`ShapeOf`, `CommandsOf`, `StoreSnapshot`,
// `StoreProxy`, …) derives from it.
//
// This package does not declare `Arbor.Stores` in the global namespace; the
// generated bundle owns those declarations and is auto-loaded by tsc as an
// ambient module.

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
// Registry-driven accessors
// ---------------------------------------------------------------------------

export type StoreModule<R> = Extract<keyof R, string>

export type DefOf<R, M extends StoreModule<R>> = R[M & keyof R]

type SymbolMarker<T> = T extends object
  ? NonNullable<T[Extract<keyof T, symbol>]>
  : never

type StoreDefMarker<T> = Extract<
  SymbolMarker<T>,
  { readonly module: string; readonly shape: unknown; readonly commands: unknown }
>

type FieldMarker<T> = Extract<
  SymbolMarker<T>,
  { readonly kind: "store" | "stream" | "async" }
>

export type ShapeOf<R, M extends StoreModule<R>> =
  [StoreDefMarker<DefOf<R, M>>] extends [never]
    ? never
    : StoreDefMarker<DefOf<R, M>> extends { readonly shape: infer Shape }
      ? Shape
      : never

export type CommandsOf<R, M extends StoreModule<R>> =
  [StoreDefMarker<DefOf<R, M>>] extends [never]
    ? never
    : StoreDefMarker<DefOf<R, M>> extends { readonly commands: infer Commands }
      ? Commands
      : never

export type CommandName<R, M extends StoreModule<R>> = keyof CommandsOf<R, M>

export type CommandPayload<
  R,
  M extends StoreModule<R>,
  K extends CommandName<R, M>
> = CommandsOf<R, M>[K] extends { payload: infer Payload } ? Payload : never

export type CommandReply<
  R,
  M extends StoreModule<R>,
  K extends CommandName<R, M>
> = CommandsOf<R, M>[K] extends { reply: infer Reply } ? Reply : unknown

// ---------------------------------------------------------------------------
// Snapshot and proxy projection (symbol-branded generated marker matching)
// ---------------------------------------------------------------------------

type FieldMarkerOfKind<T, Kind extends "store" | "stream" | "async"> = Extract<
  FieldMarker<T>,
  { readonly kind: Kind }
>

type IsStoreField<T> = [FieldMarkerOfKind<T, "store">] extends [never] ? false : true
type IsStreamField<T> = [FieldMarkerOfKind<T, "stream">] extends [never] ? false : true
type IsAsyncField<T> = [FieldMarkerOfKind<T, "async">] extends [never] ? false : true

type StoreFieldModule<T> =
  [FieldMarkerOfKind<T, "store">] extends [never]
    ? never
    : FieldMarkerOfKind<T, "store"> extends { readonly module: infer M }
      ? M
      : never
type StreamFieldItem<T> =
  [FieldMarkerOfKind<T, "stream">] extends [never]
    ? never
    : FieldMarkerOfKind<T, "stream"> extends { readonly item: infer Item }
      ? Item
      : never
type AsyncFieldValue<T> =
  [FieldMarkerOfKind<T, "async">] extends [never]
    ? never
    : FieldMarkerOfKind<T, "async"> extends { readonly value: infer Value }
      ? Value
      : never

type SnapshotAsyncValue<R, T> =
  IsStreamField<T> extends true
    ? SnapshotValue<R, StreamFieldItem<T>>[]
    : SnapshotValue<R, T>

export type SnapshotValue<R, T> =
  IsStoreField<T> extends true
    ? StoreFieldModule<T> extends infer M
      ? M extends StoreModule<R>
        ? StoreSnapshot<R, M>
        : never
      : never
    : IsAsyncField<T> extends true
      ? AsyncResult<SnapshotAsyncValue<R, AsyncFieldValue<T>>>
      : IsStreamField<T> extends true
        ? SnapshotValue<R, StreamFieldItem<T>>[]
        : T extends readonly (infer U)[]
          ? SnapshotValue<R, U>[]
          : T extends object
            ? { [K in keyof T]: SnapshotValue<R, T[K]> }
            : T

export type StoreSnapshot<R, M extends StoreModule<R>> = {
  readonly __arbor_store_id__: StoreId
} & {
  [K in keyof ShapeOf<R, M>]: SnapshotValue<R, ShapeOf<R, M>[K]>
}

export type ProxyValue<R, T> =
  IsStoreField<T> extends true
    ? StoreFieldModule<T> extends infer M
      ? M extends StoreModule<R>
        ? StoreProxy<R, M>
        : never
      : never
    : IsAsyncField<T> extends true
      ? AsyncResult<SnapshotAsyncValue<R, AsyncFieldValue<T>>>
      : IsStreamField<T> extends true
        ? SnapshotValue<R, StreamFieldItem<T>>[]
        : T extends readonly (infer U)[]
          ? SnapshotValue<R, U>[]
          : T extends object
            ? { [K in keyof T]: ProxyValue<R, T[K]> }
            : T

export interface StoreRuntime<R, M extends StoreModule<R>> {
  readonly __arbor_store_id__: StoreId
  dispatchCommand<K extends CommandName<R, M>>(
    name: K,
    payload: CommandPayload<R, M, K>
  ): Promise<CommandReply<R, M, K>>
  subscribe(listener: () => void): () => void
  snapshot(): StoreSnapshot<R, M>
}

export type StoreProxy<R, M extends StoreModule<R>> = StoreRuntime<R, M> & {
  [K in keyof ShapeOf<R, M>]: ProxyValue<R, ShapeOf<R, M>[K]>
}

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

export type StreamEntry<T> = {
  itemKey: string
  item: T
}

export type WireStreamMarker = {
  __arbor_stream__: string
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

export type ConnectionPatchEnvelope = PatchEnvelope & {
  root_id: string
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
export const STREAM_MARKER_KEY = "__arbor_stream__" as const

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
