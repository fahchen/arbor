export type StoreState = {
  __arbor_store_id__: string[]
}

export type HeaderState = StoreState & {
  signed_in: boolean
  user_name: string | null
}

export type CartLineState = StoreState & {
  id: string
  sku: string
  name: string
  price_cents: number
  qty: number
}

export type CartStatus =
  | { type: "open" }
  | { type: "checking_out" }
  | { type: "checked_out"; order_id: string }

export type CartState = StoreState & {
  lines: CartLineState[]
  subtotal_cents: number
  status: CartStatus
}

export type CartPageState = StoreState & {
  header: HeaderState
  cart: CartState
}

export type CartCommands = {
  add_item: { sku: string }
  remove_line: { id: string }
  checkout: Record<string, never>
}
