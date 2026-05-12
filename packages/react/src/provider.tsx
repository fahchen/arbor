import { createContext, useContext } from "react"
import type { ReactNode } from "react"

import type { StoreModule, StoreProxy } from "@arbor/client"

// The provider stores an opaque root store; consumers retrieve it via
// `useArborRoot<R, M>()` which projects it back to `StoreProxy<R, M>`.
type AnyStoreProxy = StoreProxy<unknown, never>

const ArborRootContext = createContext<AnyStoreProxy | null>(null)

export function ArborProvider<R, M extends StoreModule<R>>({
  store,
  children
}: {
  store: StoreProxy<R, M>
  children: ReactNode
}) {
  return (
    <ArborRootContext.Provider value={store}>
      {children}
    </ArborRootContext.Provider>
  )
}

export function useArborRoot<R, M extends StoreModule<R>>(): StoreProxy<R, M> {
  const store = useContext(ArborRootContext)

  if (!store) {
    throw new Error("useArborRoot must be used inside <ArborProvider>")
  }

  return store as StoreProxy<R, M>
}
