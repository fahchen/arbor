import { useMemo, useState } from "react"
import type { FormEvent } from "react"
import { useCommand, useStore } from "@arbor/react"

import type { CartCommands, CartPageState } from "./types"

const CART_STORE_ID = ["cart"] as const

const PRODUCT_OPTIONS = [
  { sku: "mug", label: "Coffee Mug" },
  { sku: "notebook", label: "Notebook" },
  { sku: "stickers", label: "Sticker Pack" }
] as const

export default function App() {
  const page = useStore<CartPageState>([])
  const addItem = useCommand<CartCommands, "add_item", Record<string, never> | { error: string }>(
    CART_STORE_ID,
    "add_item"
  )
  const removeLine = useCommand<CartCommands, "remove_line", Record<string, never>>(
    CART_STORE_ID,
    "remove_line"
  )
  const checkout = useCommand<CartCommands, "checkout", { order_id?: string; error?: string }>(
    CART_STORE_ID,
    "checkout"
  )

  const [sku, setSku] = useState<(typeof PRODUCT_OPTIONS)[number]["sku"]>("mug")
  const [feedback, setFeedback] = useState<string>("")
  const [busy, setBusy] = useState<"add" | "checkout" | null>(null)

  const lineCount = page?.cart.lines.reduce((sum, line) => sum + line.qty, 0) ?? 0

  const headerLabel = useMemo(() => {
    if (!page?.header) {
      return "Connecting to Arbor..."
    }

    if (!page.header.signed_in) {
      return "Guest checkout is disabled"
    }

    return `Signed in as ${page.header.user_name ?? "Unknown"}`
  }, [page?.header])

  if (!page) {
    return (
      <main className="shell">
        <section className="panel loading">Waiting for the first patch envelope…</section>
      </main>
    )
  }

  async function handleAddItem(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy("add")

    try {
      const reply = await addItem({ sku })
      setFeedback("error" in reply ? `Add failed: ${reply.error}` : `Added ${sku} to demo-cart.`)
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Add failed.")
    } finally {
      setBusy(null)
    }
  }

  async function handleCheckout() {
    setBusy("checkout")

    try {
      const reply = await checkout({})

      if (reply.order_id) {
        setFeedback(`Checkout succeeded: ${reply.order_id}`)
      } else if (reply.error) {
        setFeedback(`Checkout blocked: ${reply.error}`)
      } else {
        setFeedback("Checkout completed.")
      }
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Checkout failed.")
    } finally {
      setBusy(null)
    }
  }

  return (
    <main className="shell">
      <section className="hero">
        <p className="eyebrow">Arbor Example</p>
        <div className="hero-row">
          <div>
            <h1>Cart page</h1>
            <p className="hero-copy">
              Phoenix Channel transport + React hooks over the Arbor store tree.
            </p>
          </div>
          <div className="badge">{lineCount} items</div>
        </div>
      </section>

      <section className="grid">
        <article className="panel">
          <h2>Session</h2>
          <p>{headerLabel}</p>
          <p className="muted">Cart id: <code>demo-cart</code></p>
          <p className="muted">
            Reload the page after adding lines to see the ETS-backed mount reload path.
          </p>
        </article>

        <article className="panel">
          <h2>Add product</h2>
          <form className="stack" onSubmit={handleAddItem}>
            <label className="field">
              <span>SKU</span>
              <select value={sku} onChange={(event) => setSku(event.target.value as typeof sku)}>
                {PRODUCT_OPTIONS.map((option) => (
                  <option key={option.sku} value={option.sku}>
                    {option.label}
                  </option>
                ))}
              </select>
            </label>

            <button type="submit" disabled={busy === "add"}>
              {busy === "add" ? "Adding…" : "Add item"}
            </button>
          </form>
        </article>
      </section>

      <section className="panel">
        <div className="section-header">
          <h2>Cart lines</h2>
          <span className="status-pill">status: {page.cart.status.type}</span>
        </div>

        {page.cart.lines.length === 0 ? (
          <p className="empty">The cart is empty.</p>
        ) : (
          <ul className="lines">
            {page.cart.lines.map((line) => (
              <li key={line.__arbor_store_id__.join("/")} className="line">
                <div>
                  <strong>{line.name}</strong>
                  <p className="muted">
                    {line.sku} · qty {line.qty}
                  </p>
                </div>
                <div className="line-actions">
                  <span>{formatMoney(line.price_cents * line.qty)}</span>
                  <button type="button" className="ghost" onClick={() => void removeLine({ id: line.id })}>
                    Remove
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}

        <div className="checkout">
          <div>
            <p className="muted">Subtotal</p>
            <strong>{formatMoney(page.cart.subtotal_cents)}</strong>
          </div>
          <button type="button" onClick={() => void handleCheckout()} disabled={busy === "checkout" || page.cart.lines.length === 0}>
            {busy === "checkout" ? "Checking out…" : "Checkout"}
          </button>
        </div>

        {page.cart.status.type === "checked_out" ? (
          <p className="notice">Last order id: {page.cart.status.order_id}</p>
        ) : null}

        {feedback ? <p className="notice">{feedback}</p> : null}
      </section>
    </main>
  )
}

function formatMoney(cents: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD"
  }).format(cents / 100)
}
