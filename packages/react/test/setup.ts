import { cleanup } from "@testing-library/react"
import { afterEach } from "vitest"

import type { ArborClient, StoreId, StreamEntry } from "@arbor/client"

afterEach(() => {
  cleanup()
})

export class FakeArborClient
  implements Pick<ArborClient, "subscribe" | "getState" | "getStream" | "command">
{
  readonly commandCalls: Array<{
    storeId: StoreId
    name: string
    payload: Record<string, unknown>
  }> = []

  private readonly storeSubscribers = new Map<string, Set<() => void>>()
  private readonly states = new Map<string, unknown>()
  private readonly streams = new Map<string, readonly StreamEntry<unknown>[]>()
  private commandImpl: (
    storeId: StoreId,
    name: string,
    payload: Record<string, unknown>
  ) => Promise<unknown> = async () => undefined

  subscribe(storeId: StoreId, listener: () => void): () => void {
    const key = JSON.stringify(storeId)
    const listeners = this.storeSubscribers.get(key) ?? new Set<() => void>()

    listeners.add(listener)
    this.storeSubscribers.set(key, listeners)

    return () => {
      listeners.delete(listener)

      if (listeners.size === 0) {
        this.storeSubscribers.delete(key)
      }
    }
  }

  getState<T = unknown>(storeId: StoreId): T | undefined {
    return this.states.get(JSON.stringify(storeId)) as T | undefined
  }

  getStream<T = unknown>(storeId: StoreId, name: string): readonly StreamEntry<T>[] {
    return (this.streams.get(streamKey(storeId, name)) ?? []) as readonly StreamEntry<T>[]
  }

  async command<Reply = unknown>(
    storeId: StoreId,
    name: string,
    payload: Record<string, unknown>
  ): Promise<Reply> {
    this.commandCalls.push({ storeId, name, payload })
    return (await this.commandImpl(storeId, name, payload)) as Reply
  }

  setState(storeId: StoreId, value: unknown): void {
    this.states.set(JSON.stringify(storeId), value)
  }

  setStream(storeId: StoreId, name: string, entries: readonly StreamEntry<unknown>[]): void {
    this.streams.set(streamKey(storeId, name), entries)
  }

  emit(storeId: StoreId): void {
    const listeners = this.storeSubscribers.get(JSON.stringify(storeId))

    for (const listener of listeners ?? []) {
      listener()
    }
  }

  onCommand(
    handler: (
      storeId: StoreId,
      name: string,
      payload: Record<string, unknown>
    ) => Promise<unknown>
  ): void {
    this.commandImpl = handler
  }

  asProviderClient(): ArborClient {
    return this as unknown as ArborClient
  }
}

function streamKey(storeId: StoreId, name: string): string {
  return `${JSON.stringify(storeId)}:${name}`
}
