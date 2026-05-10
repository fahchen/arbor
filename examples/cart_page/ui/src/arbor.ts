import { Socket } from "phoenix"
import { bindStore, createArborClient } from "@arbor/client"

import type { CartPageState } from "./types"

const socket = new Socket("/socket", {})

export const client = createArborClient({ socket, topic: "page:home" })
export const rootStore = bindStore<CartPageState>(client, [])
