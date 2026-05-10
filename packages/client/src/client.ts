import { Socket } from "phoenix"

import { createEventBus } from "./events"
import type { ClientEventMap } from "./events"
import { applyPatch } from "./patch"
import {
  applyStreamOps,
  getStream,
  hasStreamKeyForStore,
  pruneStreams,
  touchedStoreKeys
} from "./streams"
import type { PatchEnvelope, StoreId, StreamEntry } from "./types"
import { storeIdKey } from "./types"

export type ArborClientOptions =
  | { socket: Socket; topic: string }
  | {
      url: string
      params?: () => Record<string, unknown>
      topic: string
      socketOptions?: ConstructorParameters<typeof Socket>[1]
    }

export interface ArborClient {
  connect(): Promise<void>
  disconnect(code?: number, reason?: string): void
  subscribe(storeId: StoreId, listener: () => void): () => void
  subscribeAll(listener: () => void): () => void
  getRoot<T = unknown>(): T | undefined
  getState<T = unknown>(storeId: StoreId): T | undefined
  getStream<T = unknown>(storeId: StoreId, streamName: string): readonly StreamEntry<T>[]
  getVersion(): number
  command<Reply = unknown>(
    storeId: StoreId,
    name: string,
    payload: Record<string, unknown>
  ): Promise<Reply>
  on<E extends keyof ClientEventMap>(
    event: E,
    handler: (payload: ClientEventMap[E]) => void
  ): () => void
}

type ChannelLike = ReturnType<Socket["channel"]>
type PushStatus = "ok" | "error" | "timeout"
type PushLike = {
  receive(status: PushStatus, callback: (payload: unknown) => void): PushLike
}

type PendingConnect = {
  generation: number
  resolve: () => void
  reject: (error: Error) => void
}

export function createArborClient(options: ArborClientOptions): ArborClient {
  return new ArborClientImpl(options)
}

class ArborClientImpl implements ArborClient {
  private readonly topic: string
  private readonly socket: Socket
  private readonly ownsSocket: boolean
  private readonly events = createEventBus<ClientEventMap>()
  private readonly storeListeners = new Map<string, Set<() => void>>()
  private readonly allListeners = new Set<() => void>()
  private readonly pendingCommandRejectors = new Set<(reason: Error) => void>()

  private channel: ChannelLike | undefined
  private channelGeneration = 0
  private root: unknown
  private version = 0
  private storeIndex = new Map<string, unknown>()
  private streams = new Map<string, readonly StreamEntry<unknown>[]>()
  private connectPromise: Promise<void> | null = null
  private pendingConnect: PendingConnect | null = null
  private recovering = false
  private suppressDisconnectEvent = false

  constructor(options: ArborClientOptions) {
    this.topic = options.topic

    if ("socket" in options) {
      this.socket = options.socket
      this.ownsSocket = false
      return
    }

    const socketOptions = { ...(options.socketOptions ?? {}) }

    if (options.params) {
      socketOptions.params = options.params
    }

    this.socket = new Socket(options.url, socketOptions)
    this.ownsSocket = true
  }

  connect(): Promise<void> {
    if (this.version >= 1 && this.channel) {
      return Promise.resolve()
    }

    if (this.connectPromise) {
      return this.connectPromise
    }

    this.connectPromise = this.connectFreshChannel().finally(() => {
      this.connectPromise = null
    })

    return this.connectPromise
  }

  disconnect(code?: number, reason?: string): void {
    this.pendingConnect?.reject(new Error("Disconnected"))
    this.pendingConnect = null
    this.rejectPendingCommands(new Error(reason ?? "Disconnected"))
    this.resetState()

    if (this.channel) {
      this.suppressDisconnectEvent = true
      this.channel.leave()
      this.channel = undefined
    }

    if (this.ownsSocket) {
      this.socket.disconnect()
    }

    this.events.emit("disconnect", { topic: this.topic, reason: reason ?? code ?? "disconnect" })
  }

  subscribe(storeId: StoreId, listener: () => void): () => void {
    const key = storeIdKey(storeId)
    const listeners = this.storeListeners.get(key) ?? new Set<() => void>()

    listeners.add(listener)
    this.storeListeners.set(key, listeners)

    return () => {
      listeners.delete(listener)

      if (listeners.size === 0) {
        this.storeListeners.delete(key)
      }
    }
  }

  subscribeAll(listener: () => void): () => void {
    this.allListeners.add(listener)
    return () => {
      this.allListeners.delete(listener)
    }
  }

  getRoot<T = unknown>(): T | undefined {
    return this.root as T | undefined
  }

  getState<T = unknown>(storeId: StoreId): T | undefined {
    return this.storeIndex.get(storeIdKey(storeId)) as T | undefined
  }

  getStream<T = unknown>(storeId: StoreId, streamName: string): readonly StreamEntry<T>[] {
    return getStream<T>(this.streams, storeId, streamName)
  }

  getVersion(): number {
    return this.version
  }

  command<Reply = unknown>(
    storeId: StoreId,
    name: string,
    payload: Record<string, unknown>
  ): Promise<Reply> {
    if (!this.channel || this.version === 0) {
      return Promise.reject(new Error("Client is not connected"))
    }

    const push = this.channel.push("command", {
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
        this.pendingCommandRejectors.delete(rejector)
      }

      this.pendingCommandRejectors.add(rejector)

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

  on<E extends keyof ClientEventMap>(
    event: E,
    handler: (payload: ClientEventMap[E]) => void
  ): () => void {
    return this.events.on(event, handler)
  }

  private async connectFreshChannel(): Promise<void> {
    // Phoenix.Socket.connect is idempotent; calling it on a caller-owned
    // socket that's already open is a no-op, while calling it on a
    // caller-owned socket the caller forgot to connect unblocks the
    // channel join.
    this.socket.connect()

    const generation = this.channelGeneration + 1
    this.channelGeneration = generation
    this.channel = this.socket.channel(this.topic, {})
    this.suppressDisconnectEvent = false

    this.channel.on("patch", (payload: PatchEnvelope) => {
      this.handlePatch(payload, generation)
    })

    this.channel.onClose((reason: unknown) => {
      if (generation !== this.channelGeneration) {
        return
      }

      if (this.suppressDisconnectEvent) {
        this.suppressDisconnectEvent = false
        return
      }

      this.handleChannelDisconnect(reason)
    })

    this.channel.onError((reason: unknown) => {
      if (generation !== this.channelGeneration) {
        return
      }

      this.handleChannelDisconnect(reason)
    })

    const initialPatch = new Promise<void>((resolve, reject) => {
      this.pendingConnect = { generation, resolve, reject }
    })

    try {
      await receivePush(this.channel.join() as PushLike)
    } catch (error) {
      this.pendingConnect = null
      this.channel = undefined
      throw error
    }

    await initialPatch
  }

  private handlePatch(envelope: PatchEnvelope, generation: number): void {
    if (generation !== this.channelGeneration) {
      return
    }

    if (this.version === 0) {
      if (envelope.base_version !== 0 || envelope.version !== 1) {
        const error = new Error("Initial patch envelope must start at version 1")
        this.pendingConnect?.reject(error)
        this.pendingConnect = null
        return
      }

      this.acceptEnvelope(envelope, true)
      return
    }

    if (envelope.base_version !== this.version || envelope.version !== this.version + 1) {
      this.events.emit("version_mismatch", {
        expected: this.version,
        receivedBaseVersion: envelope.base_version,
        envelope
      })
      void this.recoverFromVersionMismatch()
      return
    }

    this.acceptEnvelope(envelope, false)
  }

  private acceptEnvelope(envelope: PatchEnvelope, isInitial: boolean): void {
    const previousStoreIndex = this.storeIndex
    const previousStreams = this.streams
    const streamTouched = touchedStoreKeys(envelope.stream_ops)

    const nextRoot = applyPatch(this.root, envelope.ops)
    const nextStoreIndex = buildStoreIndex(nextRoot)
    const validStoreIds = new Set(nextStoreIndex.keys())
    const nextStreams = pruneStreams(applyStreamOps(this.streams, envelope.stream_ops), validStoreIds)

    this.root = nextRoot
    this.storeIndex = nextStoreIndex
    this.streams = nextStreams
    this.version = envelope.version

    this.events.emit("patch", { envelope })
    this.notifySubscribers(previousStoreIndex, nextStoreIndex, previousStreams, nextStreams, streamTouched)

    if (isInitial) {
      this.pendingConnect?.resolve()
      this.pendingConnect = null
      this.events.emit("connect", { topic: this.topic, version: this.version })
    }
  }

  private notifySubscribers(
    previousStoreIndex: ReadonlyMap<string, unknown>,
    nextStoreIndex: ReadonlyMap<string, unknown>,
    previousStreams: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
    nextStreams: ReadonlyMap<string, readonly StreamEntry<unknown>[]>,
    streamTouched: ReadonlySet<string>
  ): void {
    for (const listener of this.allListeners) {
      listener()
    }

  for (const [key, listeners] of this.storeListeners) {
      const storeChanged = !Object.is(previousStoreIndex.get(key), nextStoreIndex.get(key))
      const streamChanged = streamTouched.has(key) || hasPrunedStreamForStore(previousStreams, nextStreams, key)

      if (!storeChanged && !streamChanged) {
        continue
      }

      for (const listener of listeners) {
        listener()
      }
    }
  }

  private async recoverFromVersionMismatch(): Promise<void> {
    if (this.recovering) {
      return
    }

    this.recovering = true
    this.pendingConnect?.reject(new Error("Version mismatch"))
    this.pendingConnect = null
    this.rejectPendingCommands(new Error("Version mismatch"))
    this.resetState()

    if (this.channel) {
      this.suppressDisconnectEvent = true
      this.channel.leave()
      this.channel = undefined
    }

    try {
      await this.connectFreshChannel()
    } finally {
      this.recovering = false
    }
  }

  private handleChannelDisconnect(reason: unknown): void {
    this.pendingConnect?.reject(new Error("Disconnected"))
    this.pendingConnect = null
    this.rejectPendingCommands(new Error("Disconnected"))
    this.resetState()
    this.channel = undefined
    this.events.emit("disconnect", { topic: this.topic, reason })
  }

  private rejectPendingCommands(reason: Error): void {
    for (const rejector of this.pendingCommandRejectors) {
      rejector(reason)
    }

    this.pendingCommandRejectors.clear()
  }

  private resetState(): void {
    this.root = undefined
    this.version = 0
    this.storeIndex = new Map()
    this.streams = new Map()
  }
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

  const maybeStoreId = value.__arbor_store_id__

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
