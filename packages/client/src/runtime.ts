import { applyPatch } from "./patch"
import {
  applyStreamOps,
  hasStreamKeyForStore,
  pruneStreams,
  touchedStoreKeys
} from "./streams"
import type { PatchEnvelope, StoreId, StreamEntry } from "./types"
import { STORE_ID_KEY, storeIdKey } from "./types"

type PushStatus = "ok" | "error" | "timeout"

export interface PushLike {
  receive(status: PushStatus, callback: (payload: unknown) => void): PushLike
}

export interface ChannelLike {
  on(event: string, callback: (payload: unknown) => void): unknown
  onClose(callback: (reason: unknown) => void): unknown
  onError(callback: (reason: unknown) => void): unknown
  join(): PushLike
  push(event: string, payload: unknown): PushLike
  leave(): unknown
}

export interface SocketLike {
  connect(): unknown
  channel(topic: string, payload?: object): ChannelLike
}

type PendingConnect = {
  generation: number
  resolve: () => void
  reject: (error: Error) => void
}

export interface ConnectionListener {
  storeKey: string
  fn: () => void
}

export interface RootConnection {
  readonly module: string
  readonly id: string
  readonly topic: string

  // Mutable runtime state — read by the proxy on every property access.
  channel: ChannelLike | undefined
  channelGeneration: number
  root: unknown
  version: number
  storeIndex: Map<string, unknown>
  streams: Map<string, readonly StreamEntry<unknown>[]>
  proxyCache: Map<string, unknown>
  storeListeners: Map<string, Set<() => void>>
  pendingCommandRejectors: Set<(reason: Error) => void>
  pendingConnect: PendingConnect | null
  connectPromise: Promise<void> | null
  recovering: boolean
  suppressDisconnectEvent: boolean
}

export interface SharedRuntime {
  readonly socket: SocketLike
  readonly connections: Map<string, RootConnection>
}

const RUNTIMES: WeakMap<SocketLike, SharedRuntime> = new WeakMap()

export function getSharedRuntime(socket: SocketLike): SharedRuntime {
  const existing = RUNTIMES.get(socket)

  if (existing) {
    return existing
  }

  const runtime: SharedRuntime = { socket, connections: new Map() }
  RUNTIMES.set(socket, runtime)
  return runtime
}

export function connectionKey(module: string, id: string): string {
  return `${module}#${id}`
}

export function buildTopic(module: string, id: string): string {
  return `arbor:${encodeURIComponent(`${module}@${id}`)}`
}

export interface OpenRootOptions {
  module: string
  id: string
  params?: Record<string, unknown>
}

export function openRootConnection(
  socket: SocketLike,
  options: OpenRootOptions
): { connection: RootConnection; ready: Promise<void> } {
  const runtime = getSharedRuntime(socket)
  const key = connectionKey(options.module, options.id)
  const existing = runtime.connections.get(key)

  if (existing) {
    return { connection: existing, ready: ensureConnected(existing) }
  }

  const connection: RootConnection = {
    module: options.module,
    id: options.id,
    topic: buildTopic(options.module, options.id),
    channel: undefined,
    channelGeneration: 0,
    root: undefined,
    version: 0,
    storeIndex: new Map(),
    streams: new Map(),
    proxyCache: new Map(),
    storeListeners: new Map(),
    pendingCommandRejectors: new Set(),
    pendingConnect: null,
    connectPromise: null,
    recovering: false,
    suppressDisconnectEvent: false
  }

  runtime.connections.set(key, connection)

  const ready = connectFreshChannel(socket, connection, options.params ?? {})

  return { connection, ready }
}

export function disconnectRootConnection(
  socket: SocketLike,
  connection: RootConnection
): void {
  connection.pendingConnect?.reject(new Error("Disconnected"))
  connection.pendingConnect = null
  rejectPendingCommands(connection, new Error("Disconnected"))
  resetConnectionState(connection)

  if (connection.channel) {
    connection.suppressDisconnectEvent = true
    connection.channel.leave()
    connection.channel = undefined
  }

  const runtime = getSharedRuntime(socket)
  runtime.connections.delete(connectionKey(connection.module, connection.id))
}

export function subscribeStore(
  connection: RootConnection,
  storeId: StoreId,
  listener: () => void
): () => void {
  const key = storeIdKey(storeId)
  const listeners = connection.storeListeners.get(key) ?? new Set<() => void>()

  listeners.add(listener)
  connection.storeListeners.set(key, listeners)

  return () => {
    listeners.delete(listener)

    if (listeners.size === 0) {
      connection.storeListeners.delete(key)
    }
  }
}

export function dispatchConnectionCommand<Reply>(
  connection: RootConnection,
  storeId: StoreId,
  name: string,
  payload: unknown
): Promise<Reply> {
  if (!connection.channel || connection.version === 0) {
    return Promise.reject(new Error("Store is not connected"))
  }

  const push = connection.channel.push("command", {
    store_id: [...storeId],
    name,
    payload
  }) as PushLike

  return new Promise<Reply>((resolve, reject) => {
    const rejector = (reason: Error) => {
      cleanup()
      reject(reason)
    }

    const cleanup = () => {
      connection.pendingCommandRejectors.delete(rejector)
    }

    connection.pendingCommandRejectors.add(rejector)

    push
      .receive("ok", (reply) => {
        cleanup()
        resolve(reply as Reply)
      })
      .receive("error", (reply) => {
        cleanup()
        reject(new Error(`Command failed: ${JSON.stringify(reply)}`))
      })
      .receive("timeout", () => {
        cleanup()
        reject(new Error("Command timed out"))
      })
  })
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function ensureConnected(connection: RootConnection): Promise<void> {
  if (connection.version >= 1 && connection.channel) {
    return Promise.resolve()
  }

  if (connection.connectPromise) {
    return connection.connectPromise
  }

  return Promise.reject(new Error("Connection is not in a ready state"))
}

function connectFreshChannel(
  socket: SocketLike,
  connection: RootConnection,
  joinParams: Record<string, unknown>
): Promise<void> {
  if (connection.connectPromise) {
    return connection.connectPromise
  }

  connection.connectPromise = doConnect(socket, connection, joinParams).finally(() => {
    connection.connectPromise = null
  })

  return connection.connectPromise
}

async function doConnect(
  socket: SocketLike,
  connection: RootConnection,
  joinParams: Record<string, unknown>
): Promise<void> {
  // Phoenix.Socket.connect is idempotent.
  socket.connect()

  const generation = connection.channelGeneration + 1
  connection.channelGeneration = generation

  const joinPayload = {
    module: connection.module,
    id: connection.id,
    params: joinParams
  }

  const channel = socket.channel(connection.topic, joinPayload)
  connection.channel = channel
  connection.suppressDisconnectEvent = false

  channel.on("patch", (payload: unknown) => {
    handlePatch(socket, connection, payload as PatchEnvelope, generation, joinParams)
  })

  channel.onClose((reason: unknown) => {
    if (generation !== connection.channelGeneration) {
      return
    }

    if (connection.suppressDisconnectEvent) {
      connection.suppressDisconnectEvent = false
      return
    }

    handleChannelDisconnect(connection, reason)
  })

  channel.onError((reason: unknown) => {
    if (generation !== connection.channelGeneration) {
      return
    }

    handleChannelDisconnect(connection, reason)
  })

  const initialPatch = new Promise<void>((resolve, reject) => {
    connection.pendingConnect = { generation, resolve, reject }
  })

  try {
    await receivePush(channel.join() as PushLike)
  } catch (error) {
    connection.pendingConnect = null
    connection.channel = undefined
    throw error
  }

  await initialPatch
}

function handlePatch(
  socket: SocketLike,
  connection: RootConnection,
  envelope: PatchEnvelope,
  generation: number,
  joinParams: Record<string, unknown>
): void {
  if (generation !== connection.channelGeneration) {
    return
  }

  if (connection.version === 0) {
    if (envelope.base_version !== 0 || envelope.version !== 1) {
      const error = new Error("Initial patch envelope must start at version 1")
      connection.pendingConnect?.reject(error)
      connection.pendingConnect = null
      return
    }

    acceptEnvelope(connection, envelope, true)
    return
  }

  if (
    envelope.base_version !== connection.version ||
    envelope.version !== connection.version + 1
  ) {
    void recoverFromVersionMismatch(socket, connection, joinParams)
    return
  }

  acceptEnvelope(connection, envelope, false)
}

function acceptEnvelope(
  connection: RootConnection,
  envelope: PatchEnvelope,
  isInitial: boolean
): void {
  const previousStoreIndex = connection.storeIndex
  const previousStreams = connection.streams
  const streamTouched = touchedStoreKeys(envelope.stream_ops)

  const nextRoot = applyPatch(connection.root, envelope.ops)
  const nextStoreIndex = buildStoreIndex(nextRoot)
  const validStoreIds = new Set(nextStoreIndex.keys())
  const nextStreams = pruneStreams(
    applyStreamOps(connection.streams, envelope.stream_ops),
    validStoreIds
  )

  connection.root = nextRoot
  connection.storeIndex = nextStoreIndex
  connection.streams = nextStreams
  connection.version = envelope.version

  // Drop proxy entries whose store_id no longer exists in the tree. New
  // entries are created lazily by `proxy.ts` on demand.
  for (const key of Array.from(connection.proxyCache.keys())) {
    if (!validStoreIds.has(key)) {
      connection.proxyCache.delete(key)
    }
  }

  notifySubscribers(connection, previousStoreIndex, previousStreams, streamTouched)

  if (isInitial) {
    connection.pendingConnect?.resolve()
    connection.pendingConnect = null
  }
}

function notifySubscribers(
  connection: RootConnection,
  previousStoreIndex: ReadonlyMap<string, unknown>,
  previousStreams: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  streamTouched: ReadonlySet<string>
): void {
  for (const [key, listeners] of connection.storeListeners) {
    const storeChanged = !Object.is(
      previousStoreIndex.get(key),
      connection.storeIndex.get(key)
    )

    const streamChanged =
      streamTouched.has(key) ||
      hasPrunedStreamForStore(previousStreams, connection.streams, key)

    if (!storeChanged && !streamChanged) {
      continue
    }

    for (const listener of listeners) {
      listener()
    }
  }
}

async function recoverFromVersionMismatch(
  socket: SocketLike,
  connection: RootConnection,
  joinParams: Record<string, unknown>
): Promise<void> {
  if (connection.recovering) {
    return
  }

  connection.recovering = true
  connection.pendingConnect?.reject(new Error("Version mismatch"))
  connection.pendingConnect = null
  rejectPendingCommands(connection, new Error("Version mismatch"))
  resetConnectionState(connection)

  if (connection.channel) {
    connection.suppressDisconnectEvent = true
    connection.channel.leave()
    connection.channel = undefined
  }

  try {
    await doConnect(socket, connection, joinParams)
  } finally {
    connection.recovering = false
  }
}

function handleChannelDisconnect(connection: RootConnection, _reason: unknown): void {
  connection.pendingConnect?.reject(new Error("Disconnected"))
  connection.pendingConnect = null
  rejectPendingCommands(connection, new Error("Disconnected"))
  resetConnectionState(connection)
  connection.channel = undefined
}

function rejectPendingCommands(connection: RootConnection, reason: Error): void {
  for (const rejector of connection.pendingCommandRejectors) {
    rejector(reason)
  }

  connection.pendingCommandRejectors.clear()
}

function resetConnectionState(connection: RootConnection): void {
  connection.root = undefined
  connection.version = 0
  connection.storeIndex = new Map()
  connection.streams = new Map()
  connection.proxyCache = new Map()
}

function buildStoreIndex(root: unknown): Map<string, unknown> {
  const index = new Map<string, unknown>()
  visitStoreNodes(root, index)
  return index
}

function visitStoreNodes(value: unknown, index: Map<string, unknown>): void {
  if (Array.isArray(value)) {
    for (const entry of value) {
      visitStoreNodes(entry, index)
    }

    return
  }

  if (!isRecord(value)) {
    return
  }

  const maybeStoreId = value[STORE_ID_KEY]

  if (isStoreIdValue(maybeStoreId)) {
    index.set(storeIdKey(maybeStoreId), value)
  }

  for (const child of Object.values(value)) {
    visitStoreNodes(child, index)
  }
}

function hasPrunedStreamForStore(
  previous: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  next: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
  storeKey: string
): boolean {
  const storeId = JSON.parse(storeKey) as StoreId

  if (!hasStreamKeyForStore(previous, storeId)) {
    return false
  }

  return !hasStreamKeyForStore(next, storeId)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function isStoreIdValue(value: unknown): value is StoreId {
  return Array.isArray(value) && value.every((segment) => typeof segment === "string")
}

function receivePush(push: PushLike): Promise<unknown> {
  return new Promise((resolve, reject) => {
    push
      .receive("ok", resolve)
      .receive("error", (payload) => {
        reject(new Error(`Channel join failed: ${JSON.stringify(payload)}`))
      })
      .receive("timeout", () => {
        reject(new Error("Channel join timed out"))
      })
  })
}
