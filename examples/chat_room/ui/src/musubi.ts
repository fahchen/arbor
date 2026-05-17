import { Socket } from "phoenix"
import { connect } from "@musubi/client"

// The generated `musubi.d.ts` is ambient — tsc auto-loads it from
// `src/generated/musubi.d.ts` via the project's `include` glob, so no
// side-effect import is required.

export const socket = new Socket("/socket", {})

export const ROOT_ID = "general" as const

export const CHAT_ROOM_ROOT = {
  module: "ChatRoom.Stores.ChatRoomStore",
  id: ROOT_ID,
  params: {
    room_id: "general"
  }
} as const

export function connectMusubi() {
  return connect(socket)
}
