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

  private readonly eventHandlers = new Map<string, Array<(payload: unknown) => void>>()
  private readonly closeHandlers: Array<(reason: unknown) => void> = []
  private readonly errorHandlers: Array<(reason: unknown) => void> = []
  private readonly joinPush = new MockPush()

  left = false

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
}

class MockSocket {
  static instances: MockSocket[] = []

  readonly channels: MockChannel[] = []
  connected = false
  disconnectArgs: [number | undefined, string | undefined] | null = null

  constructor(_url: string, _options?: unknown) {
    MockSocket.instances.push(this)
  }

  connect(): void {
    this.connected = true
  }

  disconnect(code?: number, reason?: string): void {
    this.connected = false
    this.disconnectArgs = [code, reason]

    for (const channel of this.channels) {
      channel.disconnect({ code, reason })
    }
  }

  channel(_topic: string): MockChannel {
    const channel = new MockChannel()
    this.channels.push(channel)
    return channel
  }
}

vi.mock("phoenix", () => ({
  Socket: MockSocket
}))

describe("createArborClient", () => {
  beforeEach(() => {
    MockSocket.instances = []
  })

  afterEach(() => {
    vi.resetModules()
  })

  test("connect resolves only after the initial envelope is applied", async () => {
    const { createArborClient } = await import("../src/client")
    const client = createArborClient({ url: "/socket", topic: "page:1" })
    const connectPromise = client.connect()
    const channel = lastChannel()
    let resolved = false

    void connectPromise.then(() => {
      resolved = true
    })

    channel.resolveJoin()
    await Promise.resolve()
    expect(resolved).toBe(false)

    channel.emit("patch", initialEnvelope(rootState()))

    await connectPromise
    expect(client.getVersion()).toBe(1)
    expect(client.getRoot()).toEqual(rootState())
  })

  test("subsequent valid patches update local state and fire subscribeAll", async () => {
    const { createArborClient } = await import("../src/client")
    const client = createArborClient({ url: "/socket", topic: "page:1" })
    const subscriber = vi.fn()

    client.subscribeAll(subscriber)

    await connectClient(client, initialEnvelope(rootState()))

    lastChannel().emit(
      "patch",
      patchEnvelope(1, 2, [{ op: "replace", path: "/child/count", value: 2 }], [])
    )

    expect(client.getVersion()).toBe(2)
    expect(client.getState<{ count: number }>(["child"])).toMatchObject({ count: 2 })
    expect(subscriber).toHaveBeenCalledTimes(2)
  })

  test("version mismatch emits an event and leaves the stale channel", async () => {
    const { createArborClient } = await import("../src/client")
    const client = createArborClient({ url: "/socket", topic: "page:1" })
    const mismatch = vi.fn()

    client.on("version_mismatch", mismatch)
    await connectClient(client, initialEnvelope(rootState()))

    const staleChannel = lastChannel()
    staleChannel.emit("patch", patchEnvelope(99, 100, [], []))

    expect(mismatch).toHaveBeenCalledTimes(1)
    expect(staleChannel.left).toBe(true)

    const recoveryChannel = lastChannel()
    recoveryChannel.resolveJoin()
    recoveryChannel.emit("patch", initialEnvelope(rootState()))

    await waitForMicrotasks()
    expect(client.getVersion()).toBe(1)
  })

  test("command resolves on ok, rejects on error, and rejects on disconnect", async () => {
    const { createArborClient } = await import("../src/client")
    const client = createArborClient({ url: "/socket", topic: "page:1" })

    await connectClient(client, initialEnvelope(rootState()))

    const okPromise = client.command<{ ok: boolean }>(["child"], "save", { value: 1 })
    const okPush = lastCommandPush()
    okPush.resolve("ok", { ok: true })
    await expect(okPromise).resolves.toEqual({ ok: true })

    const errorPromise = client.command(["child"], "save", { value: 2 })
    lastCommandPush().resolve("error", { reason: "boom" })
    await expect(errorPromise).rejects.toThrow("Command failed")

    const disconnectPromise = client.command(["child"], "save", { value: 3 })
    lastChannel().disconnect({ reason: "socket closed" })
    await expect(disconnectPromise).rejects.toThrow("Disconnected")
  })

  test("store subscriptions only fire when that store changes", async () => {
    const { createArborClient } = await import("../src/client")
    const client = createArborClient({ url: "/socket", topic: "page:1" })
    const childListener = vi.fn()

    client.subscribe(["child"], childListener)
    await connectClient(client, initialEnvelope(rootState()))
    childListener.mockClear()

    lastChannel().emit(
      "patch",
      patchEnvelope(1, 2, [{ op: "replace", path: "/sibling/value", value: 9 }], [])
    )
    expect(childListener).toHaveBeenCalledTimes(0)

    lastChannel().emit(
      "patch",
      patchEnvelope(2, 3, [{ op: "replace", path: "/child/count", value: 4 }], [])
    )
    expect(childListener).toHaveBeenCalledTimes(1)
  })

  test("bindStore provides a typed store handle", async () => {
    const module = await import("../src/index")
    const client = module.createArborClient({ url: "/socket", topic: "page:1" })
    const store = module.bindStore<
      { count: number },
      { save: { value: number } }
    >(client, ["child"])

    await connectClient(client, initialEnvelope(rootState()))

    const commandPromise = store.command("save", { value: 5 })
    lastCommandPush().resolve("ok", { ok: true })

    await expect(commandPromise).resolves.toEqual({ ok: true })
    expect(store.getState()).toMatchObject({ count: 1 })
  })
})

function lastChannel(): MockChannel {
  const socket = MockSocket.instances.at(-1)

  if (!socket) {
    throw new Error("Missing mock socket")
  }

  const channel = socket.channels.at(-1)

  if (!channel) {
    throw new Error("Missing mock channel")
  }

  return channel
}

function lastCommandPush(): MockPush {
  const push = lastChannel().pushes.at(-1)?.push

  if (!push) {
    throw new Error("Missing command push")
  }

  return push
}

async function connectClient(
  client: { connect(): Promise<void> },
  envelope: PatchEnvelope
): Promise<void> {
  const promise = client.connect()
  const channel = lastChannel()

  channel.resolveJoin()
  channel.emit("patch", envelope)

  await promise
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
    child: {
      count: 1,
      __arbor_store_id__: ["child"]
    },
    sibling: {
      value: 1,
      __arbor_store_id__: ["sibling"]
    },
    __arbor_store_id__: []
  }
}

async function waitForMicrotasks(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}
