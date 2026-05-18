import { Socket } from "phoenix"
import { createMusubi } from "@musubi/react"
import type { MountStoreOptions } from "@musubi/react"

// One factory call binds R (the generated `Musubi.Stores`) for the
// connection and every hook. Subsequent `useMusubiRoot`, `useMusubiSnapshot`,
// and `useMusubiCommand` calls infer the store type from the `module`
// string literal alone — no generic threading at call sites.

// In dev the Vite WebSocket proxy has issues, so connect directly to the
// Phoenix backend. In production the built assets are served by Phoenix and
// the relative path works.
const SOCKET_URL = import.meta.env.DEV
  ? "ws://localhost:4003/socket"
  : "/socket"

export const socket = new Socket(SOCKET_URL, {})

export const DASHBOARD_ROOT = {
  module: "PollApp.Stores.DashboardStore",
  id: "dashboard",
  params: {}
} as const

export function pollRoomRoot(
  pollId: string
): MountStoreOptions<"PollApp.Stores.PollRoomStore", Musubi.Stores> {
  return {
    module: "PollApp.Stores.PollRoomStore",
    id: pollId,
    params: { poll_id: pollId }
  }
}

export const {
  connect,
  MusubiProvider,
  useMusubiCommand,
  useMusubiConnection,
  useMusubiRoot,
  useMusubiSnapshot
} = createMusubi<Musubi.Stores>()
