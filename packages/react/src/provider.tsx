import { createContext, useContext } from "react"
import type { ReactNode } from "react"

import type { ArborConnection } from "@arbor/client"

const ArborConnectionContext = createContext<ArborConnection | null>(null)

export function ArborProvider({
  connection,
  children
}: {
  connection: ArborConnection
  children: ReactNode
}) {
  return (
    <ArborConnectionContext.Provider value={connection}>
      {children}
    </ArborConnectionContext.Provider>
  )
}

export function useArborConnection(): ArborConnection {
  const connection = useContext(ArborConnectionContext)

  if (!connection) {
    throw new Error("useArborConnection must be used inside <ArborProvider>")
  }

  return connection
}
