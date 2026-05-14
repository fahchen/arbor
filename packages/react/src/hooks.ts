import { useCallback, useEffect, useState } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import { useArborConnection } from "./provider"

import type {
  CommandName,
  CommandPayload,
  CommandReply,
  MountStoreOptions,
  StoreModule,
  StoreProxy,
  StoreSnapshot
} from "@arbor/client"

const identitySelector = <S>(value: S): S => value

export type ArborRootMount<R, M extends StoreModule<R>> =
  | { status: "loading"; store: null; error: null }
  | { status: "ready"; store: StoreProxy<R, M>; error: null }
  | { status: "error"; store: null; error: Error }

export type UseArborRootOptions<
  R = Record<string, unknown>,
  M extends StoreModule<R> = StoreModule<R>
> = MountStoreOptions<R, M> & {
  unmountOnCleanup?: boolean
}

/**
 * Mounts a declared root store through the nearest Arbor connection.
 */
export function useArborRoot<R, M extends StoreModule<R> = StoreModule<R>>(
  options: UseArborRootOptions<R, M>
): ArborRootMount<R, M> {
  const connection = useArborConnection()
  const [state, setState] = useState<ArborRootMount<R, M>>({
    status: "loading",
    store: null,
    error: null
  })

  useEffect(() => {
    let cancelled = false
    let mounted = false
    const rootId = options.id
    const unmountOnCleanup = options.unmountOnCleanup ?? true
    const mountOptions: MountStoreOptions<R, M> = {
      module: options.module,
      id: options.id,
      ...(options.params !== undefined ? { params: options.params } : {})
    }

    setState({ status: "loading", store: null, error: null })

    connection
      .mountStore<R, M>(mountOptions)
      .then((store) => {
        mounted = true

        if (cancelled) {
          if (unmountOnCleanup) {
            void connection.unmountStore(rootId)
          }

          return
        }

        setState({ status: "ready", store, error: null })
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setState({
            status: "error",
            store: null,
            error: error instanceof Error ? error : new Error(String(error))
          })
        }
      })

    return () => {
      cancelled = true

      if (mounted && unmountOnCleanup) {
        void connection.unmountStore(rootId)
      }
    }
  }, [connection, options.module, options.id, options.params, options.unmountOnCleanup])

  return state
}

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
