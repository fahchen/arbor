import type { PatchEnvelope } from "./types"

export type ClientEventMap = {
  connect: { topic: string; version: number }
  disconnect: { topic: string; reason: unknown }
  patch: { envelope: PatchEnvelope }
  version_mismatch: {
    expected: number
    receivedBaseVersion: number
    envelope: PatchEnvelope
  }
}

type EventHandler<T> = (payload: T) => void

export interface EventBus<TEventMap extends Record<string, unknown>> {
  emit<E extends keyof TEventMap>(event: E, payload: TEventMap[E]): void
  on<E extends keyof TEventMap>(event: E, handler: EventHandler<TEventMap[E]>): () => void
}

export function createEventBus<TEventMap extends Record<string, unknown>>(): EventBus<TEventMap> {
  const listeners = new Map<keyof TEventMap, Set<EventHandler<TEventMap[keyof TEventMap]>>>()

  return {
    emit(event, payload) {
      const handlers = listeners.get(event)

      if (!handlers) {
        return
      }

      for (const handler of handlers) {
        handler(payload)
      }
    },
    on(event, handler) {
      const handlers =
        listeners.get(event) ?? new Set<EventHandler<TEventMap[keyof TEventMap]>>()

      handlers.add(handler as EventHandler<TEventMap[keyof TEventMap]>)
      listeners.set(event, handlers)

      return () => {
        handlers.delete(handler as EventHandler<TEventMap[keyof TEventMap]>)

        if (handlers.size === 0) {
          listeners.delete(event)
        }
      }
    }
  }
}
