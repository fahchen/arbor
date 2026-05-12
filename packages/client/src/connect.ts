import { getRootProxy } from "./proxy"
import {
  connectionKey,
  disconnectRootConnection,
  getSharedRuntime,
  openRootConnection
} from "./runtime"
import type { SocketLike } from "./runtime"
import type { StoreModule, StoreProxy } from "./types"

export interface ConnectStoreOptions<R, M extends StoreModule<R>> {
  module: M
  id: string
  params?: Record<string, unknown>
}

/**
 * Opens a root store connection over `socket`. The `Registry` generic is the
 * generated `<Root>.Stores` type emitted by `mix compile.arbor_ts`; the
 * module string literal is inferred from `options.module` against `Registry`.
 *
 * Usage:
 *
 *     const cart = await connectStore<MyApp.Stores>(socket, {
 *       module: "MyApp.Stores.CartPageStore",
 *       id: "cart:demo"
 *     })
 */
export async function connectStore<R, M extends StoreModule<R> = StoreModule<R>>(
  socket: SocketLike,
  options: ConnectStoreOptions<R, M>
): Promise<StoreProxy<R, M>> {
  const { connection, ready } = openRootConnection(socket, {
    module: options.module,
    id: options.id,
    ...(options.params !== undefined ? { params: options.params } : {})
  })

  await ready

  return getRootProxy<R, M>(connection)
}

export function disconnectStore<R, M extends StoreModule<R> = StoreModule<R>>(
  socket: SocketLike,
  options: { module: M; id: string }
): void {
  const runtime = getSharedRuntime(socket)
  const connection = runtime.connections.get(connectionKey(options.module, options.id))

  if (!connection) {
    return
  }

  disconnectRootConnection(socket, connection)
}
