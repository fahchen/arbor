import {
  dispatchConnectionCommand,
  subscribeStore,
  type RootConnection
} from "./runtime"
import { getStream } from "./streams"
import type {
  AsyncResult,
  StoreId,
  StoreModule,
  StoreProxy,
  StoreSnapshot,
  StreamEntry,
  WireAsyncResult
} from "./types"
import { STORE_ID_KEY, storeIdKey, streamStoreKeyPrefix } from "./types"

const ROOT_STORE_ID: StoreId = []
const RESERVED = new Set(["__arbor_store_id__", "dispatchCommand", "subscribe", "snapshot"])

export function getRootProxy<R, M extends StoreModule<R>>(
  connection: RootConnection
): StoreProxy<R, M> {
  return getProxyForStore<R, M>(connection, ROOT_STORE_ID)
}

function getProxyForStore<R, M extends StoreModule<R>>(
  connection: RootConnection,
  storeId: StoreId
): StoreProxy<R, M> {
  const key = storeIdKey(storeId)
  const cached = connection.proxyCache.get(key)

  if (cached) {
    return cached as StoreProxy<R, M>
  }

  const proxy = buildProxy(connection, storeId)
  connection.proxyCache.set(key, proxy)
  return proxy as StoreProxy<R, M>
}

function buildProxy(connection: RootConnection, storeId: StoreId): object {
  const key = storeIdKey(storeId)

  const target: Record<string, unknown> = {}

  const handler: ProxyHandler<Record<string, unknown>> = {
    get(_target, prop) {
      if (typeof prop !== "string") {
        return Reflect.get(_target, prop)
      }

      if (prop === "__arbor_store_id__") {
        return storeId
      }

      if (prop === "dispatchCommand") {
        return makeDispatchCommand(connection, storeId)
      }

      if (prop === "subscribe") {
        return (listener: () => void) => subscribeStore(connection, storeId, listener)
      }

      if (prop === "snapshot") {
        return () => snapshotStore(connection, storeId)
      }

      const node = connection.storeIndex.get(key) as Record<string, unknown> | undefined

      if (!node) {
        return undefined
      }

      return resolveField(connection, storeId, node, prop)
    },

    has(_target, prop) {
      if (typeof prop !== "string") {
        return false
      }

      if (RESERVED.has(prop)) {
        return true
      }

      const node = connection.storeIndex.get(key) as Record<string, unknown> | undefined
      return node !== undefined && prop in node
    },

    ownKeys() {
      const node = connection.storeIndex.get(key) as Record<string, unknown> | undefined
      const fieldKeys = node ? Object.keys(node).filter((k) => k !== STORE_ID_KEY) : []
      return [...RESERVED, ...fieldKeys]
    },

    getOwnPropertyDescriptor(_target, prop) {
      if (typeof prop !== "string") {
        return undefined
      }

      if (RESERVED.has(prop)) {
        return { enumerable: true, configurable: true, writable: false, value: undefined }
      }

      const node = connection.storeIndex.get(key) as Record<string, unknown> | undefined

      if (!node || !(prop in node)) {
        return undefined
      }

      return { enumerable: true, configurable: true, writable: false, value: undefined }
    },

    set() {
      throw new Error("Store proxies are read-only")
    },

    deleteProperty() {
      throw new Error("Store proxies are read-only")
    }
  }

  return new Proxy(target, handler)
}

function makeDispatchCommand(connection: RootConnection, storeId: StoreId) {
  return <Reply>(name: string, payload: unknown): Promise<Reply> =>
    dispatchConnectionCommand<Reply>(connection, storeId, name, payload)
}

// ---------------------------------------------------------------------------
// Field resolution
// ---------------------------------------------------------------------------

function resolveField(
  connection: RootConnection,
  storeId: StoreId,
  node: Record<string, unknown>,
  fieldName: string
): unknown {
  const wireValue = node[fieldName]

  // Rule 2: nested mounted store node.
  if (isStoreNode(wireValue)) {
    const childId = (wireValue as { __arbor_store_id__: StoreId }).__arbor_store_id__
    return getProxyForStore(connection, childId)
  }

  const materialized = getMaterializedStreamItems(connection, storeId, fieldName)

  if (materialized !== undefined && isWireAsyncResult(wireValue)) {
    // Rule 3: stream materialization + async wire shape.
    return normalizeAsync(wireValue, materialized)
  }

  if (materialized !== undefined) {
    // Rule 4: stream materialization only.
    return materialized
  }

  if (isWireAsyncResult(wireValue)) {
    // Rule 5: async wire shape only.
    return normalizeAsync(wireValue, wireValue.result)
  }

  // Rule 6: plain field.
  return wireValue
}

function getMaterializedStreamItems(
  connection: RootConnection,
  storeId: StoreId,
  fieldName: string
): unknown[] | undefined {
  const prefix = streamStoreKeyPrefix(storeId)
  let hit: readonly StreamEntry<unknown>[] | undefined

  for (const key of connection.streams.keys()) {
    if (!key.startsWith(prefix)) continue

    if (key.slice(prefix.length) === fieldName) {
      hit = connection.streams.get(key)
      break
    }
  }

  if (hit === undefined) {
    return undefined
  }

  const entries = getStream<unknown>(connection.streams, storeId, fieldName)
  return entries.map((entry) => entry.item)
}

function normalizeAsync<T>(wire: WireAsyncResult, data: T | null): AsyncResult<T> {
  switch (wire.status) {
    case "loading":
      return { status: "loading", data, error: null }
    case "ok":
      return { status: "ok", data: data as T, error: null }
    case "failed":
      return { status: "failed", data, error: wire.reason }
  }
}

function isStoreNode(value: unknown): value is { __arbor_store_id__: StoreId } {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false
  }

  const id = (value as Record<string, unknown>)[STORE_ID_KEY]
  return Array.isArray(id) && id.every((segment) => typeof segment === "string")
}

function isWireAsyncResult(value: unknown): value is WireAsyncResult {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false
  }

  const record = value as Record<string, unknown>
  const status = record.status
  return (
    (status === "loading" || status === "ok" || status === "failed") &&
    "result" in record &&
    "reason" in record
  )
}

// ---------------------------------------------------------------------------
// snapshot()
// ---------------------------------------------------------------------------

export function snapshotStore<R, M extends StoreModule<R>>(
  connection: RootConnection,
  storeId: StoreId
): StoreSnapshot<R, M> {
  const key = storeIdKey(storeId)
  const node = connection.storeIndex.get(key) as Record<string, unknown> | undefined

  if (!node) {
    return { __arbor_store_id__: storeId } as StoreSnapshot<R, M>
  }

  const out: Record<string, unknown> = { __arbor_store_id__: storeId }

  for (const [fieldName, wireValue] of Object.entries(node)) {
    if (fieldName === STORE_ID_KEY) continue
    out[fieldName] = snapshotField(connection, storeId, fieldName, wireValue)
  }

  return out as StoreSnapshot<R, M>
}

function snapshotField(
  connection: RootConnection,
  storeId: StoreId,
  fieldName: string,
  wireValue: unknown
): unknown {
  if (isStoreNode(wireValue)) {
    const childId = (wireValue as { __arbor_store_id__: StoreId }).__arbor_store_id__
    return snapshotStore(connection, childId)
  }

  const materialized = getMaterializedStreamItems(connection, storeId, fieldName)

  if (materialized !== undefined && isWireAsyncResult(wireValue)) {
    return normalizeAsync(wireValue, materialized)
  }

  if (materialized !== undefined) {
    return materialized
  }

  if (isWireAsyncResult(wireValue)) {
    return normalizeAsync(wireValue, wireValue.result)
  }

  return wireValue
}
