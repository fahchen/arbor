import type { Socket } from "phoenix"

import { getRootProxy } from "./proxy"
import {
  disconnectRootConnection,
  getSharedRuntime,
  openRootConnection,
  connectionKey
} from "./runtime"
import type { StoreModule, StoreProxy } from "./types"

export interface ConnectStoreOptions<M extends StoreModule> {
  module: M
  id: string
  params?: Record<string, unknown>
}

export async function connectStore<M extends StoreModule>(
  socket: Socket,
  options: ConnectStoreOptions<M>
): Promise<StoreProxy<M>> {
  const { connection, ready } = openRootConnection(socket, {
    module: options.module,
    id: options.id,
    ...(options.params !== undefined ? { params: options.params } : {})
  })

  await ready

  return getRootProxy<M>(connection)
}

export function disconnectStore<M extends StoreModule>(
  socket: Socket,
  options: { module: M; id: string }
): void {
  const runtime = getSharedRuntime(socket)
  const connection = runtime.connections.get(connectionKey(options.module, options.id))

  if (!connection) {
    return
  }

  disconnectRootConnection(socket, connection)
}
