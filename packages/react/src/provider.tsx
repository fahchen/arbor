import { createContext, useContext } from "react"
import type { ReactNode } from "react"

import type { StoreModule, StoreProxy } from "@arbor/client"

// The provider stores an opaque root proxy; consumers retrieve it via
// `useArborRoot<M>()` which projects it back to `StoreProxy<M>`.
type AnyStoreProxy = StoreProxy<StoreModule>

const ArborRootContext = createContext<AnyStoreProxy | null>(null)

export function ArborProvider<M extends StoreModule>({
  proxy,
  children
}: {
  proxy: StoreProxy<M>
  children: ReactNode
}) {
  return (
    <ArborRootContext.Provider value={proxy as AnyStoreProxy}>{children}</ArborRootContext.Provider>
  )
}

export function useArborRoot<M extends StoreModule>(): StoreProxy<M> {
  const proxy = useContext(ArborRootContext)

  if (!proxy) {
    throw new Error("useArborRoot must be used inside <ArborProvider>")
  }

  return proxy as StoreProxy<M>
}
