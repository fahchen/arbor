import { createContext, useContext } from "react"
import type { ReactNode } from "react"

import type { MusubiConnection } from "@musubi/client"

const MusubiConnectionContext = createContext<MusubiConnection | null>(null)

export function MusubiProvider({
  connection,
  children
}: {
  connection: MusubiConnection
  children: ReactNode
}) {
  return (
    <MusubiConnectionContext.Provider value={connection}>
      {children}
    </MusubiConnectionContext.Provider>
  )
}

export function useMusubiConnection(): MusubiConnection {
  const connection = useContext(MusubiConnectionContext)

  if (!connection) {
    throw new Error("useMusubiConnection must be used inside <MusubiProvider>")
  }

  return connection
}
