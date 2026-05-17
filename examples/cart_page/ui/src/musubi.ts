import { Socket } from "phoenix"
import { connect } from "@musubi/client"

// The generated `musubi.d.ts` is ambient — tsc auto-loads it from
// `src/generated/musubi.d.ts` via the project's `include` glob, so no
// side-effect import is required.

export const socket = new Socket("/socket", {})

export const ROOT_ID = "cart:demo" as const

export const CART_PAGE_ROOT = {
  module: "CartPage.Stores.CartPageStore",
  id: ROOT_ID,
  params: {
    cart_id: "demo-cart",
    current_user: { id: "u1", name: "Ada" }
  }
} as const

export function connectMusubi() {
  return connect(socket)
}
