import { useCallback } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import type { AsyncResult, StoreId, StreamEntry } from "@arbor/client"

import { useArborClient } from "./provider"

const identitySelector = <S, T = S>(value: S): T => value as unknown as T

export function useStore<TState>(storeId: StoreId): TState | undefined;
export function useStore<TState, Selected>(
  storeId: StoreId,
  selector: (state: TState | undefined) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected;
export function useStore<TState, Selected = TState | undefined>(
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
    selector ?? (identitySelector as (state: TState | undefined) => Selected)

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
  const select = useCallback(
    (state: Record<string, AsyncResult<T> | undefined> | undefined) => state?.[key],
    [key]
  )

  return useStore<Record<string, AsyncResult<T> | undefined>, AsyncResult<T> | undefined>(
    storeId,
    select
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
    identitySelector
  )
}
