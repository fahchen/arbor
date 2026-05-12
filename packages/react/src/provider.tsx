import { createContext, useContext } from "react"
import type { ReactNode } from "react"

import type { StoreModule, StoreProxy } from "@arbor/client"

// The provider stores an opaque root proxy; consumers retrieve it via
// `useArborRoot<R, M>()` which projects it back to `StoreProxy<R, M>`.
type AnyStoreProxy = StoreProxy<unknown, never>

const ArborRootContext = createContext<AnyStoreProxy | null>(null)

export function ArborProvider<R, M extends StoreModule<R>>({
  proxy,
  children
}: {
  proxy: StoreProxy<R, M>
  children: ReactNode
}) {
  return (
    <ArborRootContext.Provider value={proxy as unknown as AnyStoreProxy}>
      {children}
    </ArborRootContext.Provider>
  )
}

export function useArborRoot<R, M extends StoreModule<R>>(): StoreProxy<R, M> {
  const proxy = useContext(ArborRootContext)

  if (!proxy) {
    throw new Error("useArborRoot must be used inside <ArborProvider>")
  }

  return proxy as unknown as StoreProxy<R, M>
}
