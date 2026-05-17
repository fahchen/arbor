import { Socket } from "phoenix"
import { connect } from "@arbor/client"
import type { MountStoreOptions } from "@arbor/client"

// The generated `arbor.d.ts` is ambient — tsc auto-loads it from
// `src/generated/arbor.d.ts` via the project's `include` glob.

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
): MountStoreOptions<Arbor.Stores, "PollApp.Stores.PollRoomStore"> {
  return {
    module: "PollApp.Stores.PollRoomStore",
    id: pollId,
    params: { poll_id: pollId }
  }
}

export function connectArbor() {
  return connect(socket)
}
