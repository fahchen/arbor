# cart_page

A command-driven shopping-cart page. Demonstrates Arbor's tree composition,
the full `attach_hook` surface, the application-level persistence pattern
documented in `docs/persistence-pattern.md`, and graceful authorization
denial via `:before_command` halt-with-reply.

This example is intentionally **not a test dependency** of the main `arbor`
project. It is documentation that compiles.

## Store tree

```
CartPageStore (root)              ← attrs: cart_id, current_user (or nil)
├─ HeaderStore                    ← renders signed-in state + user name
└─ CartStore                      ← owns lines + subtotal + status; all
   │                                cart commands route to ["cart"]
   └─ CartLineStore × N           ← per-line render leaf, identity = line.id
```

## What this example demonstrates

| Arbor primitive                                               | Where it shows up                                             |
| :------------------------------------------------------------ | :------------------------------------------------------------ |
| `state do` with primitives, list of child state, variant unions | `CartStore` `:status` is `%{type: :open}` \| `:checking_out` \| `:checked_out` |
| `attr :name, type, required: true` plus `default: nil`        | `cart_id` required, `current_user` defaults to nil            |
| `command :name do payload ... end`                            | `:add_item`, `:remove_line`, `:checkout`                      |
| `command :name` (no payload)                                  | `:checkout`                                                   |
| `child(Module, id: ..., ...)` placeholder                     | `CartStore.render/1` per-line, `CartPageStore.render/1` per-widget |
| `(parent_path, module, id)` identity stability                | `CartLineStore` is keyed by `line.id` at the `child(...)` placement; identity stability is observed on the parent's `render/1` call site. The leaf itself is render-only by design. |
| `Arbor.Lifecycle.attach_hook/4` — `:before_command`           | `CartStore` `:authz` hook                                     |
| `attach_hook/4` — `:after_command`                            | `CartStore` `:audit` and `:persist` hooks                     |
| Halt-with-reply (BDR-0008) → `[:arbor, :auth, :deny]`         | Unauthenticated `:checkout` returns `%{"error" => "must_sign_in"}` |
| Application-owned persistence (`docs/persistence-pattern.md`) | `MyApp.Persistence` ETS table; load in `mount/1`, save via hook |
| Reconnect = recovery (BDR-0015)                               | Fresh page server reads cart snapshot from ETS                |
| TypeScript codegen via `:arbor_ts` Mix compiler               | Variant-union `:status` surfaces as a discriminated union     |

## Walkthrough scenarios

### 1. Page mounts and rehydrates a saved cart

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.CartPageStore,
     %{cart_id: "session-42", current_user: %{id: "u1", name: "Ada"}},
     %{transport_pid: self()}}
  )
```

Sequence:

1. Root `mount/1` runs (no-op — root carries no state).
2. Resolver mounts `HeaderStore` (records `signed_in: true`, `user_name: "Ada"`).
3. Resolver mounts `CartStore` — `mount/1` calls `Persistence.load_cart("session-42")`,
   attaches `:authz` / `:audit` / `:persist` hooks. Initial `lines: []`,
   `status: %{type: :open}`.
4. Initial `replace ""` envelope ships with the full tree at `version: 1`.

If a previous session left lines behind, the rehydrated list flows
through `CartLineStore` children automatically.

### 2. Guest user adds an item

Client sends `:add_item` to the cart at path `["cart"]`:

```elixir
Arbor.Page.Server.command(page, ["cart"], :add_item, %{"sku" => "mug"})
```

Sequence:

1. `:authz` hook runs first. Adding items is allowed for guests, so it returns `{:cont, socket}`.
2. `CartStore.handle_command(:add_item, ...)` looks up the SKU in `MyApp.Catalog` and upserts the line.
3. `:audit` hook logs the command.
4. `:persist` hook writes the new lines to ETS.
5. Reply lands first (BDR-0009: `{:ok, %{}}`).
6. Render → diff → patch envelope ships. The new `CartLineStore` mounts under `["cart", "<line_id>"]` and contributes its own subtree to the diff. `subtotal_cents` updates in the cart's own slice.

### 3. Unauthenticated checkout is gracefully denied

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.CartPageStore,
     %{cart_id: "session-99", current_user: nil},
     %{transport_pid: self()}}
  )

Arbor.Page.Server.command(page, ["cart"], :add_item, %{"sku" => "mug"})

# Add some items, then try to check out as a guest
Arbor.Page.Server.command(page, ["cart"], :checkout, %{})
#=> {:ok, %{"error" => "must_sign_in"}}
```

The `:authz` hook returns `{:halt, %{"error" => "must_sign_in"}, socket}`.

- The runtime emits `[:arbor, :auth, :deny]` with metadata `%{module: CartStore, path: ["cart"], command: :checkout, reply: %{"error" => "must_sign_in"}}` (BDR-0008).
- The handler is **not** invoked. `:lines` and `:status` are unchanged.
- `:audit` / `:persist` hooks attached on `:after_command` do not run for halted commands.
- The transport reply carries the deny payload to the client.

### 4. Successful checkout transitions the variant union

A signed-in user who adds items and checks out walks the `:status` field through the discriminated union:

```
%{type: :open}                                   →  initial
%{type: :checked_out, order_id: "order-..."}     →  after :checkout reply
```

The TypeScript codegen reflects this (see below) so the client can
exhaustively `switch` on `state.cart.status.type`.

### 5. Reconnect builds a fresh page server, loads from ETS

Because the persistence layer is the source of truth, a transport drop +
reconnect simply mounts a new `CartPageStore` — `CartStore.mount/1`
re-reads the saved lines, no in-memory state survives. This is BDR-0015
in practice.

## Run it

```sh
cd examples/cart_page
mix deps.get
mix compile
iex -S mix
```

The application starts `MyApp.Persistence` automatically. Inside `iex`:

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.CartPageStore,
     %{cart_id: "session-1", current_user: %{id: "u1", name: "Ada"}},
     %{transport_pid: self()}}
  )

flush()

Arbor.Page.Server.command(page, ["cart"], :add_item, %{"sku" => "mug"})
Arbor.Page.Server.command(page, ["cart"], :add_item, %{"sku" => "stickers"})
Arbor.Page.Server.command(page, ["cart"], :checkout, %{})

flush()

# Save survives a server restart:
:sys.get_state(page) |> elem(0)
GenServer.stop(page)

{:ok, page2} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.CartPageStore,
     %{cart_id: "session-1", current_user: %{id: "u1", name: "Ada"}},
     %{transport_pid: self()}}
  )

flush()
# initial envelope shows the persisted lines (empty here because the
# previous session checked out — try again without :checkout to see the
# rehydrate path in action).
```

## Codegen

The example wires the `:arbor_ts` Mix compiler in `mix.exs`:

```elixir
compilers: Mix.compilers() ++ [:arbor_ts]
```

`mix compile` keeps `priv/codegen/ts/arbor.ts` in sync with the `state do`
declarations. Notable bits the codegen surfaces:

```ts
export namespace MyApp {
  export namespace Stores {
    export type CartStore = {
      lines: MyApp.Stores.CartLineStore[]
      subtotal_cents: number
      status:
        | { type: "open" }
        | { type: "checking_out" }
        | { type: "checked_out"; order_id: string }
    }

    export namespace CartStore {
      export type Commands = {
        add_item: { sku: string }
        remove_line: { id: string }
        checkout: {}
      }
    }
  }
}
```

`mix compile.arbor_ts --check` (wired into `mix precommit`) fails the
build when the committed bundle drifts from the source.
