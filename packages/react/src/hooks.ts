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
export function useArborSnapshot<R, M extends StoreModule<R>>(
  proxy: StoreProxy<R, M>
): StoreSnapshot<R, M>
export function useArborSnapshot<R, M extends StoreModule<R>, Selected>(
  proxy: StoreProxy<R, M>,
  selector: (snapshot: StoreSnapshot<R, M>) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected
export function useArborSnapshot<R, M extends StoreModule<R>, Selected = StoreSnapshot<R, M>>(
  proxy: StoreProxy<R, M>,
  selector?: (snapshot: StoreSnapshot<R, M>) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected {
  const subscribe = useCallback((onChange: () => void) => proxy.subscribe(onChange), [proxy])
  const getSnapshot = useCallback(() => proxy.snapshot(), [proxy])
  const resolvedSelector =
    selector ?? (identitySelector as (snapshot: StoreSnapshot<R, M>) => Selected)

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
export function useArborCommand<
  R,
  M extends StoreModule<R>,
  K extends CommandName<R, M>
>(
  proxy: StoreProxy<R, M>,
  name: K
): (payload: CommandPayload<R, M, K>) => Promise<CommandReply<R, M, K>> {
  return useCallback(
    (payload: CommandPayload<R, M, K>) => proxy.dispatchCommand(name, payload),
    [proxy, name]
  )
}
