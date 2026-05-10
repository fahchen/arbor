import type { StoreId, StreamEntry, StreamOp } from "./types"
import { storeIdKey, storeKeyFromStreamStoreKey, streamStoreKey, streamStoreKeyPrefix } from "./types"

export type MaterializedStreamMap = Map<string, readonly StreamEntry<unknown>[]>

export function applyStreamOps(
  current: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  ops: readonly StreamOp[]
): MaterializedStreamMap {
  const next = new Map(current)

  for (const op of ops) {
    const key = streamStoreKey(op.store_id, op.stream)
    const entries = [...(next.get(key) ?? [])]

    switch (op.op) {
      case "reset":
        next.set(key, [])
        break
      case "delete":
        next.set(
          key,
          entries.filter((entry) => entry.itemKey !== op.item_key)
        )
        break
      case "insert":
        next.set(key, applyInsert(entries, op))
        break
    }
  }

  return next
}

export function getStream<T>(
  streams: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  storeId: StoreId,
  streamName: string
): readonly StreamEntry<T>[] {
  return (streams.get(streamStoreKey(storeId, streamName)) ?? []) as readonly StreamEntry<T>[]
}

export function pruneStreams(
  streams: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  validStoreIds: ReadonlySet<string>
): MaterializedStreamMap {
  const next = new Map<string, readonly StreamEntry<unknown>[]>()

  for (const [key, value] of streams) {
    const storeKey = storeKeyFromStreamStoreKey(key)

    if (validStoreIds.has(storeKey)) {
      next.set(key, value)
    }
  }

  return next
}

export function touchedStoreKeys(ops: readonly StreamOp[]): ReadonlySet<string> {
  return new Set(ops.map((op) => storeIdKey(op.store_id)))
}

export function hasStreamKeyForStore(
  streams: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  storeId: StoreId
): boolean {
  const prefix = streamStoreKeyPrefix(storeId)

  for (const key of streams.keys()) {
    if (key.startsWith(prefix)) {
      return true
    }
  }

  return false
}

function applyInsert(
  entries: StreamEntry<unknown>[],
  op: Extract<StreamOp, { op: "insert" }>
): readonly StreamEntry<unknown>[] {
  const existingIndex = entries.findIndex((entry) => entry.itemKey === op.item_key)

  if (existingIndex >= 0) {
    entries.splice(existingIndex, 1)
  }

  const nextEntry: StreamEntry<unknown> = {
    itemKey: op.item_key,
    item: op.item
  }

  const insertionIndex = resolveInsertionIndex(op.at, entries.length)
  entries.splice(insertionIndex, 0, nextEntry)

  return trimEntries(entries, op.limit, op.at)
}

function resolveInsertionIndex(at: number, length: number): number {
  if (at <= 0) {
    return at === -1 ? length : 0
  }

  return Math.min(at, length)
}

function trimEntries(
  entries: StreamEntry<unknown>[],
  limit: number | null,
  at: number
): readonly StreamEntry<unknown>[] {
  if (limit === null) {
    return entries
  }

  const size = Math.abs(limit)

  if (size === 0) {
    return []
  }

  if (entries.length <= size) {
    return entries
  }

  const overflow = entries.length - size

  if (at === 0) {
    entries.splice(entries.length - overflow, overflow)
    return entries
  }

  entries.splice(0, overflow)
  return entries
}
