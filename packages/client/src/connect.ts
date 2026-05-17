import { getRootProxy } from "./proxy"
import {
  disconnectConnectionState,
  mountConnectionRoot,
  openConnectionState,
  unmountConnectionRoot
} from "./runtime"
import type { ConnectionState, SocketLike } from "./runtime"
import type { StoreModule, StoreProxy } from "./types"

export interface ConnectOptions {
  topic?: string
}

export interface MountStoreOptions<
  R = Record<string, unknown>,
  M extends StoreModule<R> = StoreModule<R>
> {
  module: M
  id: string
  params?: Record<string, unknown>
}

export interface MusubiConnection {
  readonly topic: string
  mountStore<R, M extends StoreModule<R> = StoreModule<R>>(
    options: MountStoreOptions<R, M>
  ): Promise<StoreProxy<R, M>>
  unmountStore(rootId: string): Promise<void>
  disconnect(): void
}

/**
 * Opens one Musubi connection over `socket`.
 *
 * Usage:
 *
 *     const connection = await connect(socket)
 *
 *     const dashboard = await connection.mountStore<
 *       MyApp.Stores,
 *       "MyApp.Stores.DashboardStore"
 *     >({
 *       module: "MyApp.Stores.DashboardStore",
 *       id: "dashboard"
 *     })
 */
export async function connect(
  socket: SocketLike,
  options: ConnectOptions = {}
): Promise<MusubiConnection> {
  const { connection, ready } = openConnectionState(socket, options)
  await ready

  return buildConnectionApi(connection)
}

export async function mountStore<
  R,
  M extends StoreModule<R> = StoreModule<R>
>(
  connection: MusubiConnection,
  options: MountStoreOptions<R, M>
): Promise<StoreProxy<R, M>> {
  return connection.mountStore<R, M>(options)
}

export async function unmountStore(
  connection: MusubiConnection,
  rootId: string
): Promise<void> {
  await connection.unmountStore(rootId)
}

export function disconnect(connection: MusubiConnection): void {
  connection.disconnect()
}

function buildConnectionApi(connectionState: ConnectionState): MusubiConnection {
  return {
    topic: connectionState.topic,

    async mountStore<R, M extends StoreModule<R> = StoreModule<R>>(
      options: MountStoreOptions<R, M>
    ): Promise<StoreProxy<R, M>> {
      const { connection, ready } = mountConnectionRoot(connectionState, {
        module: options.module,
        id: options.id,
        ...(options.params !== undefined ? { params: options.params } : {})
      })

      await ready

      return getRootProxy<R, M>(connection)
    },

    async unmountStore(rootId: string): Promise<void> {
      await unmountConnectionRoot(connectionState, rootId)
    },

    disconnect(): void {
      disconnectConnectionState(connectionState)
    }
  }
}
