import { Socket } from "phoenix"
import { connectStore } from "@arbor/client"

// The generated `arbor.d.ts` is ambient — tsc auto-loads it from
// `src/generated/arbor.d.ts` via the project's `include` glob, so no
// side-effect import is required.

export const socket = new Socket("/socket", {})

export const ROOT_MODULE = "MyApp.Stores.CartPageStore" as const
export const ROOT_ID = "cart:demo" as const

export const DEFAULT_JOIN_PARAMS = {
  cart_id: "demo-cart",
  current_user: { id: "u1", name: "Ada" }
} as const

export function connectRoot() {
  return connectStore<Arbor.Stores>(socket, {
    module: ROOT_MODULE,
    id: ROOT_ID,
    params: DEFAULT_JOIN_PARAMS
  })
}
