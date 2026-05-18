import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState
} from "react"
import type { FC, ReactNode } from "react"
import { useSyncExternalStoreWithSelector } from "use-sync-external-store/shim/with-selector"

import {
  connect as baseConnect,
  MusubiCommandError,
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

import { shallowEqual } from "./shallow"

export { shallowEqual } from "./shallow"
export { MusubiCommandError, keyOf } from "@musubi/client"

export type {
  AsyncResult,
  CommandName,
  CommandPayload,
  CommandReply,
  ConnectionPatchEnvelope,
  MountStoreOptions,
  MountedStore,
  MusubiCommandErrorKind,
  MusubiCommandErrorOptions,
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

export type MusubiConnectionStatus<R> =
  | { state: "connecting"; connection: null }
  | { state: "ready"; connection: MusubiConnection<R> }
  | { state: "error"; connection: null; error: Error }

type ConnectionProviderProps<R> = {
  connection: MusubiConnection<R>
  socket?: never
  topic?: never
  children: ReactNode
}

type SocketProviderProps = {
  socket: SocketLike
  topic?: string
  connection?: never
  children: ReactNode
}

export type MusubiProviderProps<R> =
  | ConnectionProviderProps<R>
  | SocketProviderProps

export interface MusubiFactory<R> {
  connect: (socket: SocketLike, options?: ConnectOptions) => Promise<MusubiConnection<R>>
  MusubiProvider: FC<MusubiProviderProps<R>>
  useMusubiConnection: () => MusubiConnection<R>
  useMusubiConnectionStatus: () => MusubiConnectionStatus<R>
  useMusubiRoot: <M extends StoreModule<R>>(
    options: UseMusubiRootOptions<M, R>
  ) => MusubiRootMount<M, R>
  useMusubiRootSuspense: <M extends StoreModule<R>>(
    options: UseMusubiRootOptions<M, R>
  ) => StoreProxy<M, R>
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
  ) => MusubiCommandResult<M, K, R>
}

export interface MusubiCommandResult<
  M extends StoreModule<R>,
  K extends CommandName<M, R>,
  R
> {
  dispatch: (payload: CommandPayload<M, K, R>) => Promise<CommandReply<M, K, R>>
  isPending: boolean
  error: MusubiCommandError | null
  data: CommandReply<M, K, R> | null
  reset: () => void
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
 *       useMusubiRootSuspense,
 *       useMusubiSnapshot,
 *       useMusubiCommand
 *     } = createMusubi<Musubi.Stores>()
 */
export function createMusubi<R>(): MusubiFactory<R> {
  const StatusContext = createContext<MusubiConnectionStatus<R> | null>(null)

  const MusubiProvider: FC<MusubiProviderProps<R>> = (props) => {
    if (props.connection !== undefined && props.socket !== undefined) {
      throw new Error(
        "<MusubiProvider> accepts either `connection` or `socket`, not both"
      )
    }

    if (props.connection === undefined && props.socket === undefined) {
      throw new Error(
        "<MusubiProvider> requires either `connection` or `socket`"
      )
    }

    if (props.connection !== undefined) {
      return (
        <StatusContext.Provider value={{ state: "ready", connection: props.connection }}>
          {props.children}
        </StatusContext.Provider>
      )
    }

    return <SocketProvider {...props}>{props.children}</SocketProvider>
  }

  const SocketProvider: FC<SocketProviderProps> = ({ socket, topic, children }) => {
    const [status, setStatus] = useState<MusubiConnectionStatus<R>>({
      state: "connecting",
      connection: null
    })

    useEffect(() => {
      let cancelled = false
      let liveConnection: MusubiConnection<R> | null = null
      setStatus({ state: "connecting", connection: null })

      const options: ConnectOptions = topic !== undefined ? { topic } : {}

      baseConnect<R>(socket, options)
        .then((connection) => {
          if (cancelled) {
            // Race: parent unmounted (or socket/topic changed) before connect
            // resolved. Tear the freshly opened connection down immediately
            // so we don't leak a live channel.
            void connection.disconnect()
            return
          }

          liveConnection = connection
          setStatus({ state: "ready", connection })
        })
        .catch((cause: unknown) => {
          if (cancelled) return
          const error = cause instanceof Error ? cause : new Error(String(cause))
          setStatus({ state: "error", connection: null, error })
        })

      return () => {
        cancelled = true
        if (liveConnection) {
          const c = liveConnection
          liveConnection = null
          void c.disconnect()
        }
      }
    }, [socket, topic])

    return <StatusContext.Provider value={status}>{children}</StatusContext.Provider>
  }

  function useMusubiConnectionStatus(): MusubiConnectionStatus<R> {
    const status = useContext(StatusContext)
    if (!status) {
      throw new Error(
        "useMusubiConnectionStatus must be used inside <MusubiProvider>"
      )
    }
    return status
  }

  function useMusubiConnection(): MusubiConnection<R> {
    const status = useContext(StatusContext)

    if (!status) {
      throw new Error(
        "useMusubiConnection must be used inside <MusubiProvider> (or call useMusubiConnectionStatus() to observe connecting/error states)"
      )
    }

    if (status.state !== "ready") {
      throw new Error(
        `useMusubiConnection requires a ready connection (current state: ${status.state}). Use useMusubiConnectionStatus() to observe connecting/error states.`
      )
    }

    return status.connection
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

    const paramsKey = canonicalStringify(options.params ?? null)

    useEffect(() => {
      let cancelled = false
      const unmountOnCleanup = options.unmountOnCleanup ?? true
      const mountOptions: MountStoreOptions<M, R> = {
        module: options.module,
        id: options.id,
        ...(options.params !== undefined ? { params: options.params } : {})
      }

      setState({ status: "loading", store: null, error: null })

      const sharedMount = ensureRootMount<M, R>(connection, mountOptions)
      bumpMountRef(connection, sharedMount.key)

      sharedMount.promise
        .then((mounted) => {
          if (cancelled) return
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
      // paramsKey collapses logically-equal params objects so that two
      // callers passing {a:1,b:2} and {b:2,a:1} share a mount.
    }, [connection, options.module, options.id, paramsKey, options.unmountOnCleanup])

    return state
  }

  function useMusubiRootSuspense<M extends StoreModule<R>>(
    options: UseMusubiRootOptions<M, R>
  ): StoreProxy<M, R> {
    const connection = useMusubiConnection()
    const unmountOnCleanup = options.unmountOnCleanup ?? true

    const mountOptions: MountStoreOptions<M, R> = {
      module: options.module,
      id: options.id,
      ...(options.params !== undefined ? { params: options.params } : {})
    }

    // Render-phase: lookup-or-create. DO NOT bump refs here — that happens
    // in the commit-phase effect below. Suspense may discard this render.
    const sharedMount = ensureRootMount<M, R>(connection, mountOptions)
    const committedRef = useRef(false)

    useEffect(() => {
      // Commit-phase: this render won; take a ref.
      bumpMountRef(connection, sharedMount.key)
      committedRef.current = true
      return () => {
        committedRef.current = false
        releaseRootMount(connection, sharedMount.key, unmountOnCleanup)
      }
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [connection, sharedMount.key, unmountOnCleanup])

    // Schedule orphan-cleanup sweep regardless of success/failure: if no
    // commit-phase effect bumps refs by the time the promise settles, tear
    // the mount down so a discarded Suspense render doesn't leak a live
    // root, and clear the failed entry so a retry can run.
    scheduleSuspenseOrphanSweep(connection, sharedMount.key, unmountOnCleanup)

    if (sharedMount.failed) {
      throw sharedMount.error
    }

    if (!sharedMount.settled) {
      throw sharedMount.promise
    }

    return (sharedMount.value as unknown as MountedStore<M, R>).store
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
    // Default to shallowEqual when a selector is supplied so callers that
    // return fresh object/tuple literals don't re-render on every patch.
    const resolvedEquality =
      equalityFn ?? (selector ? (shallowEqual as (a: Selected, b: Selected) => boolean) : undefined)

    return useSyncExternalStoreWithSelector(
      subscribe,
      getSnapshot,
      getSnapshot,
      resolvedSelector,
      resolvedEquality
    )
  }

  const useMusubiSnapshot = useMusubiSnapshotImpl as MusubiFactory<R>["useMusubiSnapshot"]

  function useMusubiCommand<M extends StoreModule<R>, K extends CommandName<M, R>>(
    proxy: StoreProxy<M, R>,
    name: K
  ): MusubiCommandResult<M, K, R> {
    type Reply = CommandReply<M, K, R>
    const [state, setState] = useState<{
      isPending: boolean
      error: MusubiCommandError | null
      data: Reply | null
    }>({ isPending: false, error: null, data: null })

    const requestIdRef = useRef(0)
    const mountedRef = useRef(true)

    useEffect(() => {
      mountedRef.current = true
      return () => {
        mountedRef.current = false
      }
    }, [])

    const dispatch = useCallback(
      async (payload: CommandPayload<M, K, R>): Promise<Reply> => {
        const requestId = ++requestIdRef.current
        if (mountedRef.current) {
          setState({ isPending: true, error: null, data: null })
        }

        try {
          const reply = (await proxy.dispatchCommand(name, payload)) as Reply
          if (mountedRef.current && requestId === requestIdRef.current) {
            setState({ isPending: false, error: null, data: reply })
          }
          return reply
        } catch (cause) {
          const error = MusubiCommandError.is(cause)
            ? cause
            : new MusubiCommandError({
                kind: "failed",
                command: String(name),
                storeId: [...proxy.__musubi_store_id__],
                reply: { error: cause instanceof Error ? cause.message : String(cause) },
                cause
              })

          if (mountedRef.current && requestId === requestIdRef.current) {
            setState({ isPending: false, error, data: null })
          }
          throw error
        }
      },
      [proxy, name]
    )

    const reset = useCallback(() => {
      requestIdRef.current += 1
      if (mountedRef.current) {
        setState({ isPending: false, error: null, data: null })
      }
    }, [])

    return { dispatch, isPending: state.isPending, error: state.error, data: state.data, reset }
  }

  return {
    connect,
    MusubiProvider,
    useMusubiConnection,
    useMusubiConnectionStatus,
    useMusubiRoot,
    useMusubiRootSuspense,
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
  settled: boolean
  failed: boolean
  value: MountedStore<never, unknown> | null
  error: Error | null
  cleanupTimer: ReturnType<typeof setTimeout> | null
  orphanSweepScheduled: boolean
}

const pendingRootMounts: WeakMap<
  MusubiConnection<unknown>,
  Map<string, SharedRootMount>
> = new WeakMap()

/**
 * Render-phase safe: returns the existing shared mount entry or creates a new
 * one. Does NOT bump refs (the caller does that on commit). Cancels any
 * pending cleanup timer so a re-mount during the cleanup grace period reuses
 * the existing mount.
 */
function ensureRootMount<M extends StoreModule<R>, R>(
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
    return Object.assign(existing, { key })
  }

  const shared: SharedRootMount = {
    refs: 0,
    promise: Promise.resolve(null as never),
    settled: false,
    failed: false,
    value: null,
    error: null,
    cleanupTimer: null,
    orphanSweepScheduled: false
  }

  shared.promise = connection
    .mountStore(options)
    .then((mounted) => {
      shared.settled = true
      shared.value = mounted as unknown as MountedStore<never, unknown>
      return mounted as unknown as MountedStore<never, unknown>
    })
    .catch((cause: unknown) => {
      shared.settled = true
      shared.failed = true
      shared.error = cause instanceof Error ? cause : new Error(String(cause))
      // Don't delete here: the failed entry has to stay long enough for
      // Suspense/effect consumers to observe it. releaseRootMount removes
      // the entry once the last ref drops, so future mounts retry cleanly
      // (no poison).
      throw shared.error
    })
  // Swallow the unhandled rejection from the bare promise; callers that
  // .then() / .catch() this still observe the error normally.
  shared.promise.catch(() => undefined)

  mounts.set(key, shared)
  return Object.assign(shared, { key })
}

function bumpMountRef<R>(connection: MusubiConnection<R>, key: string): void {
  const mounts = pendingRootMounts.get(connection as MusubiConnection<unknown>)
  const shared = mounts?.get(key)
  if (!shared) return
  if (shared.cleanupTimer) {
    clearTimeout(shared.cleanupTimer)
    shared.cleanupTimer = null
  }
  shared.refs += 1
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

    if (!shared.failed && shared.value) {
      void shared.value.unmount()
    } else if (!shared.failed) {
      void shared.promise.then((mounted) => mounted.unmount()).catch(() => undefined)
    }
  }, 0)
}

/**
 * Suspense success-with-no-consumer path: if the promise resolves but no
 * commit-phase effect ever bumped refs, the mount is orphaned. Sweep on a
 * microtask after settle. Idempotent per (connection, key).
 */
function scheduleSuspenseOrphanSweep<R>(
  connection: MusubiConnection<R>,
  key: string,
  unmountOnCleanup: boolean
): void {
  const mounts = pendingRootMounts.get(connection as MusubiConnection<unknown>)
  const shared = mounts?.get(key)
  if (!mounts || !shared || shared.orphanSweepScheduled) return
  shared.orphanSweepScheduled = true

  const sweep = () => {
    setTimeout(() => {
      shared.orphanSweepScheduled = false
      if (shared.refs > 0) return
      // No consumer ever committed: drop the entry. On success, also unmount.
      mounts.delete(key)
      if (!shared.failed && shared.value && unmountOnCleanup) {
        void shared.value.unmount()
      }
    }, 0)
  }
  shared.promise.then(sweep, sweep)
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
  return `${options.id}|${options.module}|${canonicalStringify(options.params ?? null)}`
}

function canonicalStringify(value: unknown): string {
  // Mirror native JSON.stringify semantics for `undefined`:
  // arrays render undefined slots as "null"; objects drop undefined-valued keys.
  if (value === undefined) return "null"
  if (value === null || typeof value !== "object") return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalStringify).join(",")}]`
  const obj = value as Record<string, unknown>
  const keys = Object.keys(obj)
    .filter((k) => obj[k] !== undefined)
    .sort()
  return `{${keys
    .map((k) => `${JSON.stringify(k)}:${canonicalStringify(obj[k])}`)
    .join(",")}}`
}
