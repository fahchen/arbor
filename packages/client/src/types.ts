export type StoreId = readonly string[]

export type ArborAsyncFailure =
  | { kind: "error"; value: unknown }
  | { kind: "exit"; value: unknown }

export type AsyncResult<T> =
  | { status: "loading"; result: T | null; reason: null }
  | { status: "ok"; result: T; reason: null }
  | { status: "failed"; result: T | null; reason: ArborAsyncFailure | unknown }

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

export function storeIdKey(storeId: StoreId): string {
  return JSON.stringify(storeId)
}

export function storeIdEquals(left: StoreId, right: StoreId): boolean {
  if (left.length !== right.length) {
    return false
  }

  return left.every((segment, index) => segment === right[index])
}

export function streamStoreKey(storeId: StoreId, streamName: string): string {
  return `${storeIdKey(storeId)}::${streamName}`
}
