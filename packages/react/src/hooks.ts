import { useCallback } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import type {
  CommandName,
  CommandPayload,
  CommandReply,
  StoreModule,
  StoreProxy,
  StoreSnapshot
} from "@arbor/client"

const identitySelector = <S>(value: S): S => value

/**
 * Subscribes to a store proxy and returns its current snapshot. Re-renders
 * fire only when the underlying store node changes (per
 * `proxy.subscribe(...)` semantics).
 */
export function useArborSnapshot<M extends StoreModule>(
  proxy: StoreProxy<M>
): StoreSnapshot<M>
export function useArborSnapshot<M extends StoreModule, Selected>(
  proxy: StoreProxy<M>,
  selector: (snapshot: StoreSnapshot<M>) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected
export function useArborSnapshot<M extends StoreModule, Selected = StoreSnapshot<M>>(
  proxy: StoreProxy<M>,
  selector?: (snapshot: StoreSnapshot<M>) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected {
  const subscribe = useCallback((onChange: () => void) => proxy.subscribe(onChange), [proxy])
  const getSnapshot = useCallback(() => proxy.snapshot(), [proxy])
  const resolvedSelector =
    selector ?? (identitySelector as (snapshot: StoreSnapshot<M>) => Selected)

  return useSyncExternalStoreWithSelector(
    subscribe,
    getSnapshot,
    getSnapshot,
    resolvedSelector,
    equalityFn
  )
}

/**
 * Returns a bound dispatcher for a single command on the supplied proxy.
 */
export function useArborCommand<M extends StoreModule, K extends CommandName<M>>(
  proxy: StoreProxy<M>,
  name: K
): (payload: CommandPayload<M, K>) => Promise<CommandReply<M, K>> {
  return useCallback(
    (payload: CommandPayload<M, K>) => proxy.dispatchCommand(name, payload),
    [proxy, name]
  )
}
