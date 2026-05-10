import { Socket } from "phoenix"
import { bindStore, createArborClient } from "@arbor/client"

import "./generated/arbor"

const socket = new Socket("/socket", {})

export const client = createArborClient({ socket, topic: "page:home" })
export const rootStore = bindStore<"MyApp.Stores.ChatRoomStore">(client, [])
