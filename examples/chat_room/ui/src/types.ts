import type { AsyncResult } from "@arbor/react"

export type StoreState = {
  __arbor_store_id__: string[]
}

export type MessageState = {
  id: string
  body: string
  sender: string
}

export type OnlineUser = {
  id: string
  name: string
}

export type SendStatus =
  | { type: "idle" }
  | { type: "ok"; id: string }
  | { type: "failed"; reason: string }

export type ChatRoomState = StoreState & {
  messages: MessageState[]
  online_users: AsyncResult<OnlineUser[]>
  last_send_status: SendStatus
}

export type ChatRoomCommands = {
  reload: Record<string, never>
  refresh: Record<string, never>
  send_message: { body: string }
}
