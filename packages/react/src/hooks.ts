import { useCallback, useEffect, useState } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import { useMusubiConnection } from "./provider"

import type {
  CommandName,
  CommandPayload,
  CommandReply,
  MountStoreOptions,
  MusubiConnection,
  StoreModule,
  StoreProxy,
  StoreSnapshot
} from "@musubi/client"

const identitySelector = <S>(value: S): S => value
const pendingRootMounts: WeakMap<MusubiConnection, Map<string, SharedRootMount>> =
  new WeakMap()

type SharedRootMount = {
  rootId: string
  refs: number
  promise: Promise<StoreProxy<unknown, never>>
  failed: boolean
  cleanupTimer: ReturnType<typeof setTimeout> | null
}

export type MusubiRootMount<R, M extends StoreModule<R>> =
  | { status: "loading"; store: null; error: null }
  | { status: "ready"; store: StoreProxy<R, M>; error: null }
  | { status: "error"; store: null; error: Error }

export type UseMusubiRootOptions<
  R = Record<string, unknown>,
  M extends StoreModule<R> = StoreModule<R>
> = MountStoreOptions<R, M> & {
  unmountOnCleanup?: boolean
}

/**
 * Mounts a declared root store through the nearest Musubi connection.
 */
export function useMusubiRoot<R, M extends StoreModule<R> = StoreModule<R>>(
  options: UseMusubiRootOptions<R, M>
): MusubiRootMount<R, M> {
  const connection = useMusubiConnection()
  const [state, setState] = useState<MusubiRootMount<R, M>>({
    status: "loading",
    store: null,
    error: null
  })

  useEffect(() => {
    let cancelled = false
    const unmountOnCleanup = options.unmountOnCleanup ?? true
    const mountOptions: MountStoreOptions<R, M> = {
      module: options.module,
      id: options.id,
      ...(options.params !== undefined ? { params: options.params } : {})
    }

    setState({ status: "loading", store: null, error: null })

    const sharedMount = acquireRootMount(connection, mountOptions)

    sharedMount.promise
      .then((store) => {
        if (cancelled) {
          return
        }

        setState({ status: "ready", store: store as StoreProxy<R, M>, error: null })
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

      releaseRootMount(connection, sharedMount.key, unmountOnCleanup)
    }
  }, [connection, options.module, options.id, options.params, options.unmountOnCleanup])

  return state
}

function acquireRootMount<R, M extends StoreModule<R>>(
  connection: MusubiConnection,
  options: MountStoreOptions<R, M>
): SharedRootMount & { key: string } {
  const key = rootMountKey(options)
  const mounts = rootMountsFor(connection)
  const existing = mounts.get(key)

  if (existing) {
    if (existing.cleanupTimer) {
      clearTimeout(existing.cleanupTimer)
      existing.cleanupTimer = null
    }

    existing.refs += 1
    return { ...existing, key }
  }

  const shared: SharedRootMount = {
    rootId: options.id,
    refs: 1,
    promise: Promise.resolve(null as never),
    failed: false,
    cleanupTimer: null
  }

  shared.promise = connection
    .mountStore(options)
    .catch((error: unknown) => {
      shared.failed = true
      mounts.delete(key)
      throw error
    }) as Promise<StoreProxy<unknown, never>>

  mounts.set(key, shared)
  return { ...shared, key }
}

function releaseRootMount(
  connection: MusubiConnection,
  key: string,
  unmountOnCleanup: boolean
): void {
  const mounts = pendingRootMounts.get(connection)
  const shared = mounts?.get(key)

  if (!mounts || !shared) {
    return
  }

  shared.refs -= 1

  if (shared.refs > 0) {
    return
  }

  if (!unmountOnCleanup) {
    mounts.delete(key)
    return
  }

  shared.cleanupTimer = setTimeout(() => {
    if (shared.refs > 0) {
      return
    }

    mounts.delete(key)

    if (!shared.failed) {
      void connection.unmountStore(shared.rootId)
    }
  }, 0)
}

function rootMountsFor(connection: MusubiConnection): Map<string, SharedRootMount> {
  const existing = pendingRootMounts.get(connection)

  if (existing) {
    return existing
  }

  const mounts = new Map<string, SharedRootMount>()
  pendingRootMounts.set(connection, mounts)
  return mounts
}

function rootMountKey<R, M extends StoreModule<R>>(
  options: MountStoreOptions<R, M>
): string {
  return `${options.id}\u0000${options.module}\u0000${JSON.stringify(options.params ?? {})}`
}

/**
 * Subscribes to a store proxy and returns its current snapshot. Re-renders
 * fire only when the underlying store node changes (per
 * `proxy.subscribe(...)` semantics).
 */
export function useMusubiSnapshot<R, M extends StoreModule<R>>(
  proxy: StoreProxy<R, M>
): StoreSnapshot<R, M>
export function useMusubiSnapshot<R, M extends StoreModule<R>, Selected>(
  proxy: StoreProxy<R, M>,
  selector: (snapshot: StoreSnapshot<R, M>) => Selected,
  equalityFn?: (a: Selected, b: Selected) => boolean
): Selected
export function useMusubiSnapshot<R, M extends StoreModule<R>, Selected = StoreSnapshot<R, M>>(
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
export function useMusubiCommand<
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
