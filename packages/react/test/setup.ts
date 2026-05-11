import { cleanup } from "@testing-library/react"
import { afterEach } from "vitest"

import type { StoreModule, StoreProxy, StoreSnapshot } from "@arbor/client"

afterEach(() => {
  cleanup()
})

/**
 * Minimal stand-in for a real `StoreProxy<M>` used by the React adapter
 * tests. The fake exposes the four reserved runtime members and a settable
 * snapshot/dispatch impl, but skips proxy field access — tests assert on
 * snapshot values, not on bracket-style field reads through the proxy.
 */
export class FakeStoreProxy<M extends StoreModule> {
  readonly __arbor_store_id__: string[] = []

  private snapshotValue: StoreSnapshot<M>
  private readonly subscribers = new Set<() => void>()

  readonly dispatchCalls: Array<{ name: string; payload: unknown }> = []
  private dispatchImpl: (name: string, payload: unknown) => Promise<unknown> = async () =>
    undefined

  constructor(initialSnapshot: StoreSnapshot<M>) {
    this.snapshotValue = initialSnapshot
  }

  subscribe = (listener: () => void): (() => void) => {
    this.subscribers.add(listener)
    return () => {
      this.subscribers.delete(listener)
    }
  }

  snapshot = (): StoreSnapshot<M> => this.snapshotValue

  dispatchCommand = async (name: string, payload: unknown): Promise<unknown> => {
    this.dispatchCalls.push({ name, payload })
    return this.dispatchImpl(name, payload)
  }

  setSnapshot(next: StoreSnapshot<M>): void {
    this.snapshotValue = next
    for (const listener of this.subscribers) listener()
  }

  onDispatch(impl: (name: string, payload: unknown) => Promise<unknown>): void {
    this.dispatchImpl = impl
  }

  asProxy(): StoreProxy<M> {
    return this as unknown as StoreProxy<M>
  }
}
