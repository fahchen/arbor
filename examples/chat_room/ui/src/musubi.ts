import { Socket } from "phoenix"
import { createMusubi } from "@musubi/react"

// One factory call binds R (the generated `Musubi.Stores`) for the
// connection and every hook. Subsequent `useMusubiRoot`, `useMusubiSnapshot`,
// and `useMusubiCommand` calls infer the store type from the `module`
// string literal alone — no generic threading at call sites.

export const socket = new Socket("/socket", {})

export const ROOT_ID = "general" as const

export const CHAT_ROOM_ROOT = {
  module: "ChatRoom.Stores.ChatRoomStore",
  id: ROOT_ID,
  params: {
    room_id: "general"
  }
} as const

export const {
  connect,
  MusubiProvider,
  useMusubiCommand,
  useMusubiConnection,
  useMusubiRoot,
  useMusubiSnapshot
} = createMusubi<Musubi.Stores>()
