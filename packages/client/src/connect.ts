import { getRootProxy } from "./proxy"
import {
  disconnectConnectionState,
  mountConnectionRoot,
  openConnectionState,
  unmountConnectionRoot
} from "./runtime"
import type { ConnectionState, SocketLike } from "./runtime"
import type { Registry, StoreModule, StoreProxy } from "./types"

export interface ConnectOptions {
  topic?: string
}

export interface MountStoreOptions<
  M extends StoreModule<R>,
  R = Registry
> {
  module: M
  id: string
  params?: Record<string, unknown>
}

export interface MountedStore<M extends StoreModule<R>, R = Registry> {
  readonly store: StoreProxy<M, R>
  readonly unmount: () => Promise<void>
}

export interface MusubiConnection<R = Registry> {
  readonly topic: string
  mountStore<M extends StoreModule<R>>(
    options: MountStoreOptions<M, R>
  ): Promise<MountedStore<M, R>>
  disconnect(): Promise<void>
}

/**
 * Opens one Musubi connection over `socket`.
 *
 * Usage:
 *
 *     const connection = await connect<Musubi.Stores>(socket)
 *
 *     const { store, unmount } = await connection.mountStore({
 *       module: "MyApp.Stores.DashboardStore",
 *       id: "dashboard"
 *     })
 *
 * The `R` generic is bound once on `connect`; the `module` literal then
 * drives type inference for every later `mountStore` call. React consumers
 * usually go through `createMusubi<R>()` in `@musubi/react` instead, which
 * binds `R` once for the connection and all hooks.
 */
export async function connect<R = Registry>(
  socket: SocketLike,
  options: ConnectOptions = {}
): Promise<MusubiConnection<R>> {
  const { connection, ready } = openConnectionState(socket, options)
  await ready

  return buildConnectionApi<R>(connection)
}

function buildConnectionApi<R>(connectionState: ConnectionState): MusubiConnection<R> {
  return {
    topic: connectionState.topic,

    async mountStore<M extends StoreModule<R>>(
      options: MountStoreOptions<M, R>
    ): Promise<MountedStore<M, R>> {
      const { connection, ready } = mountConnectionRoot(connectionState, {
        module: options.module,
        id: options.id,
        ...(options.params !== undefined ? { params: options.params } : {})
      })

      await ready

      const store = getRootProxy<M, R>(connection)
      let unmounted = false
      const unmount = (): Promise<void> => {
        if (unmounted) {
          return Promise.resolve()
        }

        unmounted = true
        return unmountConnectionRoot(connectionState, options.id)
      }

      return { store, unmount }
    },

    async disconnect(): Promise<void> {
      await disconnectConnectionState(connectionState)
    }
  }
}
