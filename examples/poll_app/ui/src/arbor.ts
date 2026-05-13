import { Socket } from "phoenix"
import { connectStore } from "@arbor/client"

// The generated `arbor.d.ts` is ambient — tsc auto-loads it from
// `src/generated/arbor.d.ts` via the project's `include` glob.

// In dev the Vite WebSocket proxy has issues, so connect directly to the
// Phoenix backend. In production the built assets are served by Phoenix and
// the relative path works.
const SOCKET_URL = import.meta.env.DEV
  ? "ws://localhost:4003/socket"
  : "/socket"

export const socket = new Socket(SOCKET_URL, {})

export function connectDashboard() {
  return connectStore<Arbor.Stores>(socket, {
    module: "MyApp.Stores.DashboardStore",
    id: "dashboard",
    params: {}
  })
}

export function connectPollRoom(pollId: string) {
  return connectStore<Arbor.Stores>(socket, {
    module: "MyApp.Stores.PollRoomStore",
    id: pollId,
    params: { poll_id: pollId }
  })
}
