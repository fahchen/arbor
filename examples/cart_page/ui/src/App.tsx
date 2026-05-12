import { useMemo, useState } from "react"
import type { SubmitEvent } from "react"
import { useArborCommand, useArborRoot, useArborSnapshot } from "@arbor/react"

type Registry = Arbor.Stores
type RootModule = "MyApp.Stores.CartPageStore"

const PRODUCT_OPTIONS = [
  {
    sku: "mug",
    label: "Coffee Mug",
    detail: "Ceramic desk cup",
    priceCents: 1_500,
    tone: "clay"
  },
  {
    sku: "notebook",
    label: "Notebook",
    detail: "Dot-grid field book",
    priceCents: 800,
    tone: "ink"
  },
  {
    sku: "stickers",
    label: "Sticker Pack",
    detail: "Die-cut labels",
    priceCents: 500,
    tone: "mint"
  }
] as const

export default function App() {
  const root = useArborRoot<Registry, RootModule>()
  const page = useArborSnapshot(root)

  const cartProxy = root.cart
  const addItem = useArborCommand(cartProxy, "add_item")
  const removeLine = useArborCommand(cartProxy, "remove_line")
  const checkout = useArborCommand(cartProxy, "checkout")

  const [sku, setSku] = useState<(typeof PRODUCT_OPTIONS)[number]["sku"]>("mug")
  const [feedback, setFeedback] = useState<string>("")
  const [busy, setBusy] = useState<"add" | "checkout" | "remove" | null>(null)

  const selectedProduct = useMemo(
    () => PRODUCT_OPTIONS.find((option) => option.sku === sku) ?? PRODUCT_OPTIONS[0],
    [sku]
  )

  const headerLabel = useMemo(() => {
    if (!page.header) {
      return "Connecting to Arbor..."
    }

    if (!page.header.signed_in) {
      return "Guest checkout is disabled"
    }

    return `Signed in as ${page.header.user_name ?? "Unknown"}`
  }, [page.header])

  async function handleAddItem(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy("add")

    try {
      const reply = (await addItem({ sku })) as Record<string, never> | { error: string }
      setFeedback(
        "error" in reply
          ? `Add failed: ${reply.error}`
          : `Added ${selectedProduct.label} to demo-cart.`
      )
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Add failed.")
    } finally {
      setBusy(null)
    }
  }

  async function handleCheckout() {
    setBusy("checkout")

    try {
      const reply = (await checkout({})) as { order_id?: string; error?: string }

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

  async function handleRemoveLine(id: string) {
    setBusy("remove")

    try {
      await removeLine({ id })
      setFeedback("Line removed.")
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Remove failed.")
    } finally {
      setBusy(null)
    }
  }

  return (
    <main className="shell">
      <header className="hero">
        <div className="hero-copy">
          <p className="eyebrow">Arbor Storefront Runtime</p>
          <h1>Cart control room</h1>
          <p>
            An Arbor store driving a React cart with server-owned state, command replies,
            persistence, and reconnect recovery.
          </p>
        </div>

        <div className="hero-metrics" aria-label="Cart quantity summary">
          <div>
            <span className="metric-label">Session</span>
            <strong>{page.header?.signed_in ? "Signed in" : "Guest"}</strong>
          </div>
          <div>
            <span className="metric-label">Product types</span>
            <strong>{page.cart.lines.length}</strong>
          </div>
          <div>
            <span className="metric-label">Total units</span>
            <strong>{page.cart.total_units}</strong>
          </div>
        </div>
      </header>

      <section className="session-strip" aria-label="Runtime notes">
        <p>{headerLabel}</p>
        <p>
          Cart id <code>demo-cart</code>
        </p>
        <p>Reload after adding lines to exercise the ETS-backed mount reload path.</p>
      </section>

      <div className="workspace">
        <section className="catalog" aria-labelledby="catalog-heading">
          <div className="section-heading">
            <p className="eyebrow">Command target: cart</p>
            <h2 id="catalog-heading">Add product</h2>
          </div>

          <form className="catalog-form" onSubmit={handleAddItem}>
            <fieldset>
              <legend className="sr-only">Choose a product SKU</legend>
              <div className="product-grid">
                {PRODUCT_OPTIONS.map((option) => (
                  <label
                    key={option.sku}
                    className="product-card"
                    data-tone={option.tone}
                    data-selected={option.sku === sku}
                    onClick={() => setSku(option.sku)}
                  >
                    <input
                      type="radio"
                      name="sku"
                      value={option.sku}
                      checked={option.sku === sku}
                      onChange={() => setSku(option.sku)}
                    />
                    <span className="product-art" aria-hidden="true">
                      <span />
                    </span>
                    <span className="product-copy">
                      <strong>{option.label}</strong>
                      <span>{option.detail}</span>
                    </span>
                    <span className="product-price">{formatMoney(option.priceCents)}</span>
                  </label>
                ))}
              </div>
            </fieldset>

            <div className="command-bar">
              <div>
                <span className="metric-label">Selected SKU</span>
                <strong>{selectedProduct.sku}</strong>
              </div>
              <button type="submit" disabled={busy === "add"}>
                {busy === "add" ? "Adding..." : `Add ${selectedProduct.label}`}
              </button>
            </div>
          </form>
        </section>

        <section className="cart-panel" aria-labelledby="cart-heading">
          <div className="cart-header">
            <div>
              <p className="eyebrow">Server snapshot</p>
              <h2 id="cart-heading">Cart lines</h2>
            </div>
            <span className="status-pill" data-status={page.cart.status.type}>
              {formatStatus(page.cart.status.type)}
            </span>
          </div>

          {page.cart.lines.length === 0 ? (
            <div className="empty">
              <strong>No lines yet</strong>
              <p>Add a product to watch the store tree update through Arbor.</p>
            </div>
          ) : (
            <ul className="lines">
              {page.cart.lines.map((line) => (
                <li key={line.__arbor_store_id__.join("/")} className="line">
                  <div className="line-main">
                    <strong>{line.name}</strong>
                    <span>
                      {line.sku} / qty {line.qty}
                    </span>
                  </div>
                  <div className="line-actions">
                    <span>{formatMoney(line.price_cents * line.qty)}</span>
                    <button
                      type="button"
                      className="ghost"
                      onClick={() => void handleRemoveLine(line.id)}
                      disabled={busy === "remove"}
                    >
                      Remove
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}

          <div className="checkout">
            <div>
              <span className="metric-label">Subtotal</span>
              <strong>{formatMoney(page.cart.subtotal_cents)}</strong>
            </div>
            <button
              type="button"
              onClick={() => void handleCheckout()}
              disabled={busy === "checkout" || page.cart.lines.length === 0}
            >
              {busy === "checkout" ? "Checking out..." : "Checkout"}
            </button>
          </div>

          {page.cart.status.type === "checked_out" ? (
            <p className="notice">Last order id: {page.cart.status.order_id}</p>
          ) : null}

          {feedback ? (
            <p className="notice" role="status" aria-live="polite">
              {feedback}
            </p>
          ) : null}
        </section>
      </div>
    </main>
  )
}

function formatStatus(status: string): string {
  return status
    .split("_")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

function formatMoney(cents: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD"
  }).format(cents / 100)
}
