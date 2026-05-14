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
  WireAsyncResult,
  WireStreamMarker
} from "./types"
import { STORE_ID_KEY, STREAM_MARKER_KEY, storeIdKey, streamStoreKeyPrefix } from "./types"

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
  return resolveValue(connection, storeId, wireValue, fieldName)
}

function resolveValue(
  connection: RootConnection,
  storeId: StoreId,
  wireValue: unknown,
  fieldName?: string
): unknown {
  // Rule 2: nested mounted store node.
  if (isStoreNode(wireValue)) {
    const childId = (wireValue as { __arbor_store_id__: StoreId }).__arbor_store_id__
    return getProxyForStore(connection, childId)
  }

  if (isWireStreamMarker(wireValue)) {
    return getMaterializedStreamItems(connection, storeId, wireValue[STREAM_MARKER_KEY])
  }

  if (isWireAsyncResult(wireValue)) {
    const materialized = fieldName
      ? getMaterializedStreamItemsIfPresent(connection, storeId, fieldName)
      : undefined

    // Rule 3: async stream field, or async wire shape only.
    return normalizeAsync(wireValue, materialized ?? wireValue.result)
  }

  if (Array.isArray(wireValue)) {
    return wireValue.map((item) => resolveValue(connection, storeId, item))
  }

  if (isPlainRecord(wireValue)) {
    return Object.fromEntries(
      Object.entries(wireValue).map(([key, value]) => [
        key,
        resolveValue(connection, storeId, value, key)
      ])
    )
  }

  // Rule 4: plain field.
  return wireValue
}

function getMaterializedStreamItems(
  connection: RootConnection,
  storeId: StoreId,
  streamName: string
): unknown[] {
  const entries = getStream<unknown>(connection.streams, storeId, streamName)
  return entries.map((entry) => entry.item)
}

function getMaterializedStreamItemsIfPresent(
  connection: RootConnection,
  storeId: StoreId,
  streamName: string
): unknown[] | undefined {
  const prefix = streamStoreKeyPrefix(storeId)
  let hit: readonly StreamEntry<unknown>[] | undefined

  for (const key of connection.streams.keys()) {
    if (!key.startsWith(prefix)) continue

    if (key.slice(prefix.length) === streamName) {
      hit = connection.streams.get(key)
      break
    }
  }

  if (hit === undefined) {
    return undefined
  }

  return hit.map((entry) => entry.item)
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

function isWireStreamMarker(value: unknown): value is WireStreamMarker {
  return (
    isPlainRecord(value) &&
    typeof value[STREAM_MARKER_KEY] === "string" &&
    Object.keys(value).length === 1
  )
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

// ---------------------------------------------------------------------------
// snapshot()
// ---------------------------------------------------------------------------

export function snapshotStore<R, M extends StoreModule<R>>(
  connection: RootConnection,
  storeId: StoreId
): StoreSnapshot<R, M> {
  const key = storeIdKey(storeId)
  const cached = connection.snapshotCache.get(key)

  if (cached) {
    return cached as StoreSnapshot<R, M>
  }

  const node = connection.storeIndex.get(key) as Record<string, unknown> | undefined

  if (!node) {
    const missing = { __arbor_store_id__: storeId } as StoreSnapshot<R, M>
    connection.snapshotCache.set(key, missing)
    return missing
  }

  const out: Record<string, unknown> = { __arbor_store_id__: storeId }

  for (const [fieldName, wireValue] of Object.entries(node)) {
    if (fieldName === STORE_ID_KEY) continue
    out[fieldName] = snapshotField(connection, storeId, fieldName, wireValue)
  }

  const snapshot = out as StoreSnapshot<R, M>
  connection.snapshotCache.set(key, snapshot)
  return snapshot
}

function snapshotField(
  connection: RootConnection,
  storeId: StoreId,
  fieldName: string,
  wireValue: unknown
): unknown {
  return snapshotValue(connection, storeId, wireValue, fieldName)
}

function snapshotValue(
  connection: RootConnection,
  storeId: StoreId,
  wireValue: unknown,
  fieldName?: string
): unknown {
  if (isStoreNode(wireValue)) {
    const childId = (wireValue as { __arbor_store_id__: StoreId }).__arbor_store_id__
    return snapshotStore(connection, childId)
  }

  if (isWireStreamMarker(wireValue)) {
    return getMaterializedStreamItems(connection, storeId, wireValue[STREAM_MARKER_KEY])
  }

  if (isWireAsyncResult(wireValue)) {
    const materialized = fieldName
      ? getMaterializedStreamItemsIfPresent(connection, storeId, fieldName)
      : undefined

    return normalizeAsync(wireValue, materialized ?? wireValue.result)
  }

  if (Array.isArray(wireValue)) {
    return wireValue.map((item) => snapshotValue(connection, storeId, item))
  }

  if (isPlainRecord(wireValue)) {
    return Object.fromEntries(
      Object.entries(wireValue).map(([key, value]) => [
        key,
        snapshotValue(connection, storeId, value, key)
      ])
    )
  }

  return wireValue
}
