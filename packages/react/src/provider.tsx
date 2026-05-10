import { createContext, useContext } from "react"
import type { ReactNode } from "react"

import type { ArborClient } from "@arbor/client"

const ArborClientContext = createContext<ArborClient | null>(null)

export function ArborProvider({
  client,
  children
}: {
  client: ArborClient
  children: ReactNode
}) {
  return <ArborClientContext.Provider value={client}>{children}</ArborClientContext.Provider>
}

export function useArborClient(): ArborClient {
  const client = useContext(ArborClientContext)

  if (!client) {
    throw new Error("useArborClient must be used inside <ArborProvider>")
  }

  return client
}
