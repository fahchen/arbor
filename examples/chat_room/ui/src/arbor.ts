import { Socket } from "phoenix"
import { connectStore } from "@arbor/client"

import "./generated/arbor"

export const socket = new Socket("/socket", {})

export const ROOT_MODULE = "MyApp.Stores.ChatRoomStore" as const
export const ROOT_ID = "general" as const

export const DEFAULT_JOIN_PARAMS = {
  room_id: "general"
} as const

export function connectRoot() {
  return connectStore(socket, {
    module: ROOT_MODULE,
    id: ROOT_ID,
    params: DEFAULT_JOIN_PARAMS as unknown as Record<string, unknown>
  })
}
