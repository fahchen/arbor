import { afterEach, beforeEach, describe, expect, test, vi } from "vitest"

import type { PatchEnvelope } from "../src/types"

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

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Arbor {
    interface Stores {
      "Test.Store": Arbor.StoreDef<
        "Test.Store",
        {
          title: string
          child: Arbor.StoreField<"Test.Child">
          counter: number
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
  }
}

describe("connectStore", () => {
  beforeEach(() => {
    MockSocket.instances = []
  })

  afterEach(() => {
    vi.resetModules()
  })

  test("connect resolves only after the initial envelope is applied", async () => {
    const { connectStore } = await import("../src/connect")
    const socket = new MockSocket()
    let resolved = false

    const proxyPromise = connectStore(socket, {
      module: "Test.Store",
      id: "root"
    })

    void proxyPromise.then(() => {
      resolved = true
    })

    const channel = lastChannel(socket)
    expect(channel.joinPayload).toEqual({
      module: "Test.Store",
      id: "root",
      params: {}
    })

    channel.resolveJoin()
    await Promise.resolve()
    expect(resolved).toBe(false)

    channel.emit("patch", initialEnvelope(rootState()))

    const proxy = await proxyPromise
    expect(proxy.title).toBe("Inbox")
    expect(proxy.counter).toBe(1)
    expect((proxy as unknown as { __arbor_store_id__: string[] }).__arbor_store_id__).toEqual([])
  })

  test("nested store field returns a stable child proxy", async () => {
    const { connectStore } = await import("../src/connect")
    const socket = new MockSocket()
    const proxyPromise = connectStore(socket, {
      module: "Test.Store",
      id: "root"
    })

    const channel = lastChannel(socket)
    channel.resolveJoin()
    channel.emit("patch", initialEnvelope(rootState()))

    const proxy = await proxyPromise

    expect(proxy.child).toBe(proxy.child)
    expect(proxy.child.count).toBe(1)
  })

  test("dispatchCommand sends a command and resolves with the reply", async () => {
    const { connectStore } = await import("../src/connect")
    const socket = new MockSocket()
    const proxyPromise = connectStore(socket, {
      module: "Test.Store",
      id: "root"
    })

    const channel = lastChannel(socket)
    channel.resolveJoin()
    channel.emit("patch", initialEnvelope(rootState()))

    const proxy = await proxyPromise
    const replyPromise = proxy.dispatchCommand("rename", { title: "Outbox" })

    const lastPush = channel.pushes.at(-1)
    expect(lastPush?.event).toBe("command")
    expect(lastPush?.payload).toEqual({
      store_id: [],
      name: "rename",
      payload: { title: "Outbox" }
    })

    lastPush?.push.resolve("ok", { ok: true })
    await expect(replyPromise).resolves.toEqual({ ok: true })
  })

  test("subscribe fires when the store node mutates", async () => {
    const { connectStore } = await import("../src/connect")
    const socket = new MockSocket()
    const proxyPromise = connectStore(socket, {
      module: "Test.Store",
      id: "root"
    })

    const channel = lastChannel(socket)
    channel.resolveJoin()
    channel.emit("patch", initialEnvelope(rootState()))

    const proxy = await proxyPromise
    const listener = vi.fn()
    proxy.subscribe(listener)

    channel.emit(
      "patch",
      patchEnvelope(1, 2, [{ op: "replace", path: "/counter", value: 9 }], [])
    )

    expect(listener).toHaveBeenCalledTimes(1)
    expect(proxy.counter).toBe(9)
  })

  test("snapshot returns a plain object tree", async () => {
    const { connectStore } = await import("../src/connect")
    const socket = new MockSocket()
    const proxyPromise = connectStore(socket, {
      module: "Test.Store",
      id: "root"
    })

    const channel = lastChannel(socket)
    channel.resolveJoin()
    channel.emit("patch", initialEnvelope(rootState()))

    const proxy = await proxyPromise
    const snapshot = proxy.snapshot()

    expect(snapshot).toEqual({
      __arbor_store_id__: [],
      title: "Inbox",
      counter: 1,
      child: { __arbor_store_id__: ["child"], count: 1 }
    })
  })
})

function lastChannel(socket: MockSocket): MockChannel {
  const channel = socket.channels.at(-1)

  if (!channel) {
    throw new Error("Missing mock channel")
  }

  return channel
}

function initialEnvelope(value: Record<string, unknown>): PatchEnvelope {
  return patchEnvelope(0, 1, [{ op: "replace", path: "", value }], [])
}

function patchEnvelope(
  baseVersion: number,
  version: number,
  ops: PatchEnvelope["ops"],
  streamOps: PatchEnvelope["stream_ops"]
): PatchEnvelope {
  return {
    type: "patch",
    base_version: baseVersion,
    version,
    ops,
    stream_ops: streamOps
  }
}

function rootState(): Record<string, unknown> {
  return {
    title: "Inbox",
    counter: 1,
    child: {
      count: 1,
      __arbor_store_id__: ["child"]
    },
    __arbor_store_id__: []
  }
}
