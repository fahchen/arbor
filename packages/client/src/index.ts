export { createArborClient } from "./client"
export type { ArborClient, ArborClientOptions } from "./client"
export type { ClientEventMap } from "./events"
export { applyPatch, parsePointer } from "./patch"
export { applyStreamOps, getStream, pruneStreams } from "./streams"
export type {
  ArborAsyncFailure,
  AsyncResult,
  JsonPatchOp,
  PatchEnvelope,
  StoreId,
  StreamEntry,
  StreamOp
} from "./types"

import type { ArborClient } from "./client"
import type { StoreId } from "./types"

export interface BoundStore<
  TState,
  TCommands extends Record<string, Record<string, unknown>> = {}
> {
  readonly storeId: StoreId
  getState(): TState | undefined
  subscribe(listener: () => void): () => void
  command<K extends keyof TCommands, Reply = unknown>(
    name: K,
    payload: TCommands[K]
  ): Promise<Reply>
}

export function bindStore<
  TState,
  TCommands extends Record<string, Record<string, unknown>> = {}
>(client: ArborClient, storeId: StoreId): BoundStore<TState, TCommands> {
  return {
    storeId,
    getState() {
      return client.getState<TState>(storeId)
    },
    subscribe(listener) {
      return client.subscribe(storeId, listener)
    },
    command(name, payload) {
      return client.command(storeId, String(name), payload)
    }
  }
}
