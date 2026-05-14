import { afterEach, beforeEach, describe, expect, test, vi } from "vitest"

import type { PatchEnvelope, ConnectionPatchEnvelope, SnapshotValue } from "../src/types"

type PushStatus = "ok" | "error" | "timeout"
type PushCallback = (payload: unknown) => void

class MockPush {
  private readonly callbacks = new Map<PushStatus, PushCallback[]>()

  receive(status: PushStatus, callback: PushCallback): this {
    const listeners = this.callbacks.get(status) ?? []
    listeners.push(callback)
    this.callbacks.set(status, listeners)
    return this
  }

  resolve(status: PushStatus, payload: unknown): void {
    for (const callback of this.callbacks.get(status) ?? []) {
      callback(payload)
    }
  }
}

class MockChannel {
  readonly pushes: Array<{ event: string; payload: unknown; push: MockPush }> = []
  readonly joinPayload: unknown

  private readonly eventHandlers = new Map<string, Array<(payload: unknown) => void>>()
  private readonly closeHandlers: Array<(reason: unknown) => void> = []
  private readonly errorHandlers: Array<(reason: unknown) => void> = []
  private readonly joinPush = new MockPush()

  left = false

  constructor(_topic: string, joinPayload?: unknown) {
    this.joinPayload = joinPayload
  }

  on(event: string, callback: (payload: unknown) => void): void {
    const handlers = this.eventHandlers.get(event) ?? []
    handlers.push(callback)
    this.eventHandlers.set(event, handlers)
  }

  onClose(callback: (reason: unknown) => void): void {
    this.closeHandlers.push(callback)
  }

  onError(callback: (reason: unknown) => void): void {
    this.errorHandlers.push(callback)
  }

  join(): MockPush {
    return this.joinPush
  }

  push(event: string, payload: unknown): MockPush {
    const push = new MockPush()
    this.pushes.push({ event, payload, push })
    return push
  }

  leave(): void {
    this.left = true

    for (const callback of this.closeHandlers) {
      callback({ reason: "leave" })
    }
  }

  resolveJoin(payload: unknown = {}): void {
    this.joinPush.resolve("ok", payload)
  }

  emit(event: string, payload: unknown): void {
    for (const callback of this.eventHandlers.get(event) ?? []) {
      callback(payload)
    }
  }

  disconnect(reason: unknown): void {
    for (const callback of this.closeHandlers) {
      callback(reason)
    }
  }

  fail(reason: unknown): void {
    for (const callback of this.errorHandlers) {
      callback(reason)
    }
  }
}

class MockSocket {
  static instances: MockSocket[] = []

  readonly channels: MockChannel[] = []
  connected = false

  constructor(_url?: string, _options?: unknown) {
    MockSocket.instances.push(this)
  }

  connect(): void {
    this.connected = true
  }

  disconnect(): void {
    this.connected = false

    for (const channel of this.channels) {
      channel.disconnect({ reason: "socket closed" })
    }
  }

  channel(topic: string, payload?: unknown): MockChannel {
    const channel = new MockChannel(topic, payload)
    this.channels.push(channel)
    return channel
  }
}

vi.mock("phoenix", () => ({
  Socket: MockSocket
}))

type TestStores = {
  "Test.Store": Arbor.StoreDef<
    "Test.Store",
    {
      title: string
      child: Arbor.StoreField<"Test.Child">
      counter: number
      feed: {
        messages: Arbor.StreamField<{ body: string }>
      }
      async_messages: Arbor.AsyncField<Arbor.StreamField<{ id: string; body: string }>>
      metadata: {
        messages: string
      }
      users: Arbor.StreamField<{ id: string; name: string }>
    },
    {
      rename: {
        payload: { title: string }
        reply: { ok: true }
      }
    }
  >

  "Test.Child": Arbor.StoreDef<
    "Test.Child",
    {
      count: number
    },
    {}
  >
}

type Equal<Left, Right> =
  (<T>() => T extends Left ? 1 : 2) extends (<T>() => T extends Right ? 1 : 2)
  ? true
  : false

type Assert<T extends true> = T

type PlainObjectSnapshot = Assert<
  Equal<SnapshotValue<TestStores, { title: string }>, { title: string }>
>

type EmptyObjectSnapshot = Assert<Equal<SnapshotValue<TestStores, {}>, {}>>

describe("connect", () => {
  beforeEach(() => {
    MockSocket.instances = []
  })

  afterEach(() => {
    vi.resetModules()
  })

  test("joins one Arbor connection channel", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)

    const channel = lastChannel(socket)
    expect(channel.joinPayload).toEqual({})
    expect(socket.connected).toBe(true)

    channel.resolveJoin()

    const connection = await connectionPromise
    expect(connection.topic).toBe("arbor:connection")
  })

  test("mountStore resolves only after the root initial envelope is applied", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise
    let resolved = false

    const proxyPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1",
      params: { room_id: "general" }
    })
    await Promise.resolve()

    void proxyPromise.then(() => {
      resolved = true
    })

    const mountPush = lastPush(channel)
    expect(mountPush.event).toBe("mount")
    expect(mountPush.payload).toEqual({
      module: "Test.Store",
      id: "alpha-1",
      params: { room_id: "general" }
    })

    mountPush.push.resolve("ok", { root_id: "alpha-1" })
    await Promise.resolve()
    expect(resolved).toBe(false)

    channel.emit("patch", initialConnectionEnvelope("alpha-1", rootState()))

    const proxy = await proxyPromise
    expect(proxy.title).toBe("Inbox")
    expect(proxy.counter).toBe(1)
    expect(proxy.__arbor_store_id__).toEqual([])
  })

  test("nested store field returns a stable child proxy", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise
    const proxyPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1"
    })
    await Promise.resolve()

    lastPush(channel).push.resolve("ok", { root_id: "alpha-1" })
    channel.emit("patch", initialConnectionEnvelope("alpha-1", rootState()))

    const proxy = await proxyPromise

    expect(proxy.child).toBe(proxy.child)
    expect(proxy.child.count).toBe(1)
  })

  test("dispatchCommand sends root_id with the command", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise
    const proxyPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1"
    })
    await Promise.resolve()

    lastPush(channel).push.resolve("ok", { root_id: "alpha-1" })
    channel.emit("patch", initialConnectionEnvelope("alpha-1", rootState()))

    const proxy = await proxyPromise
    const replyPromise = proxy.dispatchCommand("rename", { title: "Outbox" })

    const commandPush = lastPush(channel)
    expect(commandPush.event).toBe("command")
    expect(commandPush.payload).toEqual({
      root_id: "alpha-1",
      store_id: [],
      name: "rename",
      payload: { title: "Outbox" }
    })

    commandPush.push.resolve("ok", { ok: true })
    await expect(replyPromise).resolves.toEqual({ ok: true })
  })

  test("patches are routed by root_id", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise

    const alphaPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1"
    })
    await Promise.resolve()
    lastPush(channel).push.resolve("ok", { root_id: "alpha-1" })
    channel.emit("patch", initialConnectionEnvelope("alpha-1", rootState()))
    const alpha = await alphaPromise

    const betaPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "beta-1"
    })
    await Promise.resolve()
    lastPush(channel).push.resolve("ok", { root_id: "beta-1" })
    channel.emit("patch", initialConnectionEnvelope("beta-1", rootState("Secondary")))
    const beta = await betaPromise

    const alphaListener = vi.fn()
    const betaListener = vi.fn()
    alpha.subscribe(alphaListener)
    beta.subscribe(betaListener)

    channel.emit(
      "patch",
      connectionEnvelope(
        "beta-1",
        1,
        2,
        [{ op: "replace", path: "/counter", value: 9 }],
        []
      )
    )

    expect(alpha.counter).toBe(1)
    expect(beta.counter).toBe(9)
    expect(alphaListener).not.toHaveBeenCalled()
    expect(betaListener).toHaveBeenCalledTimes(1)
  })

  test("mountStore reuses the existing root for duplicate ids in one connection", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise

    const firstPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "shared-root"
    })
    await Promise.resolve()
    const firstPushCount = channel.pushes.length
    lastPush(channel).push.resolve("ok", { root_id: "shared-root" })
    channel.emit("patch", initialConnectionEnvelope("shared-root", rootState()))
    const firstProxy = await firstPromise

    const secondProxy = await connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "shared-root"
    })

    expect(secondProxy).toBe(firstProxy)
    // No second mount push: dedup reuses the in-memory entry. The server is
    // the source of truth for duplicate-mount errors; locally we just attach.
    expect(channel.pushes.length).toBe(firstPushCount)
  })

  test("snapshot returns a plain object tree", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise
    const proxyPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1"
    })
    await Promise.resolve()

    lastPush(channel).push.resolve("ok", { root_id: "alpha-1" })
    channel.emit("patch", initialConnectionEnvelope("alpha-1", rootState()))

    const proxy = await proxyPromise
    const snapshot = proxy.snapshot()

    expect(snapshot).toEqual({
      __arbor_store_id__: [],
      title: "Inbox",
      counter: 1,
      feed: { messages: [] },
      async_messages: { status: "loading", data: [], error: null },
      metadata: { messages: "literal" },
      users: [],
      child: { __arbor_store_id__: ["child"], count: 1 }
    })
  })

  test("stream markers resolve at nested paths", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise
    const proxyPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1"
    })
    await Promise.resolve()

    lastPush(channel).push.resolve("ok", { root_id: "alpha-1" })
    channel.emit(
      "patch",
      connectionEnvelope(
        "alpha-1",
        0,
        1,
        [{ op: "replace", path: "", value: rootState() }],
        [
          {
            op: "insert",
            stream: "messages",
            ref: "1",
            store_id: [],
            item_key: "messages-1",
            at: -1,
            item: { body: "hello" },
            limit: null
          },
          {
            op: "insert",
            stream: "async_messages",
            ref: "3",
            store_id: [],
            item_key: "async_messages-1",
            at: -1,
            item: { id: "a1", body: "loaded" },
            limit: null
          },
          {
            op: "insert",
            stream: "users",
            ref: "2",
            store_id: [],
            item_key: "users-u1",
            at: -1,
            item: { id: "u1", name: "Ada" },
            limit: null
          }
        ]
      )
    )

    const proxy = await proxyPromise

    expect(proxy.feed.messages).toEqual([{ body: "hello" }])
    expect(proxy.async_messages).toEqual({
      status: "loading",
      data: [{ id: "a1", body: "loaded" }],
      error: null
    })
    expect(proxy.metadata.messages).toBe("literal")
    expect(proxy.users).toEqual([{ id: "u1", name: "Ada" }])
    expect(proxy.snapshot().feed.messages).toEqual([{ body: "hello" }])
    expect(proxy.snapshot().async_messages).toEqual({
      status: "loading",
      data: [{ id: "a1", body: "loaded" }],
      error: null
    })
    expect(proxy.snapshot().metadata.messages).toBe("literal")
  })

  test("unmountStore sends an unmount push and resets the root runtime", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise
    const proxyPromise = connection.mountStore<TestStores, "Test.Store">({
      module: "Test.Store",
      id: "alpha-1"
    })
    await Promise.resolve()

    lastPush(channel).push.resolve("ok", { root_id: "alpha-1" })
    channel.emit("patch", initialConnectionEnvelope("alpha-1", rootState()))

    const proxy = await proxyPromise
    const unmountPromise = connection.unmountStore("alpha-1")
    const unmountPush = lastPush(channel)

    expect(unmountPush.event).toBe("unmount")
    expect(unmountPush.payload).toEqual({ root_id: "alpha-1" })

    unmountPush.push.resolve("ok", {})
    await unmountPromise

    expect(proxy.title).toBeUndefined()
    await expect(proxy.dispatchCommand("rename", { title: "Gone" })).rejects.toThrow(
      /Store is not connected/
    )
  })

  test("disconnect leaves the connection channel", async () => {
    const { connect } = await import("../src/connect")
    const socket = new MockSocket()
    const connectionPromise = connect(socket)
    const channel = lastChannel(socket)
    channel.resolveJoin()
    const connection = await connectionPromise

    connection.disconnect()

    expect(channel.left).toBe(true)
  })
})

function lastChannel(socket: MockSocket): MockChannel {
  const channel = socket.channels.at(-1)

  if (!channel) {
    throw new Error("Missing mock channel")
  }

  return channel
}

function lastPush(channel: MockChannel): {
  event: string
  payload: unknown
  push: MockPush
} {
  const push = channel.pushes.at(-1)

  if (!push) {
    throw new Error("Missing mock push")
  }

  return push
}

function initialConnectionEnvelope(
  rootId: string,
  value: Record<string, unknown>
): ConnectionPatchEnvelope {
  return connectionEnvelope(rootId, 0, 1, [{ op: "replace", path: "", value }], [])
}

function connectionEnvelope(
  rootId: string,
  baseVersion: number,
  version: number,
  ops: PatchEnvelope["ops"],
  streamOps: PatchEnvelope["stream_ops"]
): ConnectionPatchEnvelope {
  return {
    type: "patch",
    root_id: rootId,
    base_version: baseVersion,
    version,
    ops,
    stream_ops: streamOps
  }
}

function rootState(title = "Inbox"): Record<string, unknown> {
  return {
    title,
    counter: 1,
    child: {
      count: 1,
      __arbor_store_id__: ["child"]
    },
    feed: {
      messages: { __arbor_stream__: "messages" }
    },
    async_messages: {
      __arbor_async__: true,
      status: "loading",
      result: { __arbor_stream__: "async_messages" },
      reason: null
    },
    metadata: {
      messages: "literal"
    },
    users: { __arbor_stream__: "users" },
    __arbor_store_id__: []
  }
}
