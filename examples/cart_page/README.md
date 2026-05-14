# cart_page

A command-driven shopping cart example built as a small Arbor store tree. It
demonstrates child store composition, command routing to a nested cart store,
lifecycle hooks for auth/audit, shared cart storage, cross-tab synchronization,
and reconnect recovery through the application persistence layer.

## Store tree

```text
CartPage.Stores.CartPageStore (root)
  attrs: cart_id, current_user
  state:
    header  CartPage.Stores.HeaderStore
    cart    CartPage.Stores.CartStore

  CartPage.Stores.HeaderStore ("header")
    attrs: current_user
    state:
      signed_in  boolean
      user_name  string | nil

  CartPage.Stores.CartStore ("cart")
    attrs: cart_id, current_user
    state:
      lines           list(CartPage.Stores.CartLineStore)
      subtotal_cents  integer
      status          open | checking_out | checked_out

    CartPage.Stores.CartLineStore ("<line id>")
      attrs: line
      state:
        id, sku, name, price_cents, qty
```

## Commands

Cart commands route to the `["cart"]` store path.

| Command | Payload | Reply | Behavior |
| :-- | :-- | :-- | :-- |
| `add_item` | `{ sku: string }` | none or `{ error: "unknown_sku" }` | Adds a product line or increments the existing line quantity. |
| `remove_line` | `{ id: string }` | none | Removes a cart line by line id. |
| `checkout` | `{}` | `{ order_id: string }` or `{ error: "must_sign_in" }` | Requires a signed-in user, clears the cart, and marks the cart checked out. |

## Start the example

From the repository root:

```sh
cd examples/cart_page
mix deps.get
mix compile
mix run --no-halt
```

In another terminal:

```sh
cd examples/cart_page/ui
pnpm install
pnpm dev
```

Open http://localhost:4101.
