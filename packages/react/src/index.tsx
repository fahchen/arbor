import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState
} from "react"
import type { FC, ReactNode } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import {
  connect as baseConnect,
  type ConnectOptions,
  type MountStoreOptions,
  type MountedStore,
  type MusubiConnection,
  type SocketLike,
  type StoreModule,
  type StoreProxy,
  type StoreSnapshot,
  type CommandName,
  type CommandPayload,
  type CommandReply
} from "@musubi/client"

export { shallowEqual } from "./shallow"

export type {
  AsyncResult,
  CommandName,
  CommandPayload,
  CommandReply,
  ConnectionPatchEnvelope,
  MountStoreOptions,
  MountedStore,
  MusubiConnection,
  PatchEnvelope,
  StoreId,
  StoreModule,
  StoreProxy,
  StoreSnapshot,
  StreamEntry,
  StreamOp
} from "@musubi/client"

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export type MusubiRootMount<M extends StoreModule<R>, R> =
  | { status: "loading"; store: null; error: null }
  | { status: "ready"; store: StoreProxy<M, R>; error: null }
  | { status: "error"; store: null; error: Error }

export type UseMusubiRootOptions<
  M extends StoreModule<R>,
  R
> = MountStoreOptions<M, R> & {
  unmountOnCleanup?: boolean
}

export interface MusubiFactory<R> {
  connect: (socket: SocketLike, options?: ConnectOptions) => Promise<MusubiConnection<R>>
  MusubiProvider: FC<{ connection: MusubiConnection<R>; children: ReactNode }>
  useMusubiConnection: () => MusubiConnection<R>
  useMusubiRoot: <M extends StoreModule<R>>(
    options: UseMusubiRootOptions<M, R>
  ) => MusubiRootMount<M, R>
  useMusubiSnapshot: {
    <M extends StoreModule<R>>(proxy: StoreProxy<M, R>): StoreSnapshot<M, R>
    <M extends StoreModule<R>, Selected>(
      proxy: StoreProxy<M, R>,
      selector: (snapshot: StoreSnapshot<M, R>) => Selected,
      equalityFn?: (a: Selected, b: Selected) => boolean
    ): Selected
  }
  useMusubiCommand: <M extends StoreModule<R>, K extends CommandName<M, R>>(
    proxy: StoreProxy<M, R>,
    name: K
  ) => (payload: CommandPayload<M, K, R>) => Promise<CommandReply<M, K, R>>
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/**
 * Returns a Musubi API closed over the registry `R`.
 *
 * Usage:
 *
 *     export const {
 *       connect,
 *       MusubiProvider,
 *       useMusubiRoot,
 *       useMusubiSnapshot,
 *       useMusubiCommand
 *     } = createMusubi<Musubi.Stores>()
 *
 * Each call returns a fresh React context and hook set, so multiple
 * factories can coexist (tests, multi-registry setups). `R` is required —
 * pass your generated `Musubi.Stores` type (or any store-map type).
 */
export function createMusubi<R>(): MusubiFactory<R> {
  const ConnectionContext = createContext<MusubiConnection<R> | null>(null)

  const MusubiProvider: FC<{
    connection: MusubiConnection<R>
    children: ReactNode
  }> = ({ connection, children }) => (
    <ConnectionContext.Provider value={connection}>{children}</ConnectionContext.Provider>
  )

  function useMusubiConnection(): MusubiConnection<R> {
    const connection = useContext(ConnectionContext)

    if (!connection) {
      throw new Error("useMusubiConnection must be used inside <MusubiProvider>")
    }

    return connection
  }

  function connect(
    socket: SocketLike,
    options?: ConnectOptions
  ): Promise<MusubiConnection<R>> {
    return baseConnect<R>(socket, options)
  }

  function useMusubiRoot<M extends StoreModule<R>>(
    options: UseMusubiRootOptions<M, R>
  ): MusubiRootMount<M, R> {
    const connection = useMusubiConnection()
    const [state, setState] = useState<MusubiRootMount<M, R>>({
      status: "loading",
      store: null,
      error: null
    })

    useEffect(() => {
      let cancelled = false
      const unmountOnCleanup = options.unmountOnCleanup ?? true
      const mountOptions: MountStoreOptions<M, R> = {
        module: options.module,
        id: options.id,
        ...(options.params !== undefined ? { params: options.params } : {})
      }

      setState({ status: "loading", store: null, error: null })

      const sharedMount = acquireRootMount<M, R>(connection, mountOptions)

      sharedMount.promise
        .then((mounted) => {
          if (cancelled) {
            return
          }

          setState({
            status: "ready",
            store: mounted.store as StoreProxy<M, R>,
            error: null
          })
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

  function useMusubiSnapshotImpl<M extends StoreModule<R>, Selected>(
    proxy: StoreProxy<M, R>,
    selector?: (snapshot: StoreSnapshot<M, R>) => Selected,
    equalityFn?: (a: Selected, b: Selected) => boolean
  ): Selected | StoreSnapshot<M, R> {
    const subscribe = useCallback((onChange: () => void) => proxy.subscribe(onChange), [proxy])
    const getSnapshot = useCallback(() => proxy.snapshot(), [proxy])
    const resolvedSelector =
      selector ?? ((value: StoreSnapshot<M, R>) => value as unknown as Selected)

    return useSyncExternalStoreWithSelector(
      subscribe,
      getSnapshot,
      getSnapshot,
      resolvedSelector,
      equalityFn
    )
  }

  const useMusubiSnapshot = useMusubiSnapshotImpl as MusubiFactory<R>["useMusubiSnapshot"]

  function useMusubiCommand<M extends StoreModule<R>, K extends CommandName<M, R>>(
    proxy: StoreProxy<M, R>,
    name: K
  ): (payload: CommandPayload<M, K, R>) => Promise<CommandReply<M, K, R>> {
    return useCallback(
      (payload: CommandPayload<M, K, R>) => proxy.dispatchCommand(name, payload),
      [proxy, name]
    )
  }

  return {
    connect,
    MusubiProvider,
    useMusubiConnection,
    useMusubiRoot,
    useMusubiSnapshot,
    useMusubiCommand
  }
}

// ---------------------------------------------------------------------------
// Shared mount ref-counting across hook callers
// ---------------------------------------------------------------------------

type SharedRootMount = {
  refs: number
  promise: Promise<MountedStore<never, unknown>>
  failed: boolean
  cleanupTimer: ReturnType<typeof setTimeout> | null
}

const pendingRootMounts: WeakMap<
  MusubiConnection<unknown>,
  Map<string, SharedRootMount>
> = new WeakMap()

function acquireRootMount<M extends StoreModule<R>, R>(
  connection: MusubiConnection<R>,
  options: MountStoreOptions<M, R>
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
    }) as unknown as Promise<MountedStore<never, unknown>>

  mounts.set(key, shared)
  return { ...shared, key }
}

function releaseRootMount<R>(
  connection: MusubiConnection<R>,
  key: string,
  unmountOnCleanup: boolean
): void {
  const mounts = pendingRootMounts.get(connection as MusubiConnection<unknown>)
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
      void shared.promise.then((mounted) => mounted.unmount())
    }
  }, 0)
}

function rootMountsFor<R>(
  connection: MusubiConnection<R>
): Map<string, SharedRootMount> {
  const key = connection as MusubiConnection<unknown>
  const existing = pendingRootMounts.get(key)

  if (existing) {
    return existing
  }

  const mounts = new Map<string, SharedRootMount>()
  pendingRootMounts.set(key, mounts)
  return mounts
}

function rootMountKey<M extends StoreModule<R>, R>(
  options: MountStoreOptions<M, R>
): string {
  return `${options.id}|${options.module}|${JSON.stringify(options.params ?? {})}`
}
