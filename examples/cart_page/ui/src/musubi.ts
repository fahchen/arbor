import { Socket } from "phoenix"
import { createMusubi } from "@musubi/react"

// One factory call binds R (the generated `Musubi.Stores`) for the
// connection and every hook. Subsequent `useMusubiRoot`, `useMusubiSnapshot`,
// and `useMusubiCommand` calls infer the store type from the `module`
// string literal alone — no generic threading at call sites.
//
// tsc auto-loads `src/generated/musubi.d.ts` via the project's `include`
// glob; no side-effect import required.

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

export const {
  connect,
  MusubiProvider,
  useMusubiCommand,
  useMusubiConnection,
  useMusubiRoot,
  useMusubiSnapshot
} = createMusubi<Musubi.Stores>()
