import { useCallback } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import type { AsyncResult, StoreId, StreamEntry } from "@arbor/client"

import { useArborClient } from "./provider"

export function useStore<TState, Selected = TState>(
  storeId: StoreId,
  selector?: (state: TState | undefined) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected {
  const client = useArborClient()
  const storeIdKey = JSON.stringify(storeId)

  const subscribe = useCallback(
    (onChange: () => void) => client.subscribe(storeId, onChange),
    [client, storeIdKey]
  )
  const getSnapshot = useCallback(() => client.getState<TState>(storeId), [client, storeIdKey])
  const resolvedSelector =
    selector ?? ((state: TState | undefined) => state as unknown as Selected)

  return useSyncExternalStoreWithSelector(
    subscribe,
    getSnapshot,
    getSnapshot,
    resolvedSelector,
    equalityFn
  )
}

export function useCommand<
  TCommands extends Record<string, Record<string, unknown>>,
  K extends keyof TCommands & string,
  Reply = unknown
>(storeId: StoreId, name: K): (payload: TCommands[K]) => Promise<Reply> {
  const client = useArborClient()
  const storeIdKey = JSON.stringify(storeId)

  return useCallback(
    (payload: TCommands[K]) => client.command<Reply>(storeId, name, payload),
    [client, storeIdKey, name]
  )
}

export function useAsyncResult<T>(storeId: StoreId, key: string): AsyncResult<T> | undefined {
  return useStore<Record<string, AsyncResult<T> | undefined>, AsyncResult<T> | undefined>(
    storeId,
    (state) => state?.[key]
  )
}

export function useStream<T>(storeId: StoreId, name: string): readonly StreamEntry<T>[] {
  const client = useArborClient()
  const storeIdKey = JSON.stringify(storeId)

  const subscribe = useCallback(
    (onChange: () => void) => client.subscribe(storeId, onChange),
    [client, storeIdKey]
  )
  const getSnapshot = useCallback(() => client.getStream<T>(storeId, name), [client, storeIdKey, name])

  return useSyncExternalStoreWithSelector(
    subscribe,
    getSnapshot,
    getSnapshot,
    (stream) => stream,
    (a, b) => a === b
  )
}
