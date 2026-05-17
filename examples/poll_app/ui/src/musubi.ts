import { Socket } from "phoenix"
import { connect } from "@musubi/client"
import type { MountStoreOptions } from "@musubi/client"

// The generated `musubi.d.ts` is ambient — tsc auto-loads it from
// `src/generated/musubi.d.ts` via the project's `include` glob.

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
): MountStoreOptions<Musubi.Stores, "PollApp.Stores.PollRoomStore"> {
  return {
    module: "PollApp.Stores.PollRoomStore",
    id: pollId,
    params: { poll_id: pollId }
  }
}

export function connectMusubi() {
  return connect(socket)
}
