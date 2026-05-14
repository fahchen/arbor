import { Socket } from "phoenix"
import { connect } from "@arbor/client"

// The generated `arbor.d.ts` is ambient — tsc auto-loads it from
// `src/generated/arbor.d.ts` via the project's `include` glob, so no
// side-effect import is required.

export const socket = new Socket("/socket", {})

export const ROOT_ID = "general" as const

export const CHAT_ROOM_ROOT = {
  module: "MyApp.Stores.ChatRoomStore",
  id: ROOT_ID,
  params: {
    room_id: "general"
  }
} as const

export function connectArbor() {
  return connect(socket)
}
