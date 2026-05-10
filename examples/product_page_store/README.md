# product_page_store

Reference implementation of the §Complete Example in `docs/PRD.md`. A root
`MyApp.Stores.ProductPageStore` composes four child stores: header, filters,
product cards, and notifications.

## What this example demonstrates

| Arbor primitive                       | Where it shows up                                                 |
| :------------------------------------ | :---------------------------------------------------------------- |
| Multi-store tree                      | One root + four children mounted under it                         |
| `child(Module, id: ..., ...)`         | Inside `ProductPageStore.to_state/1`                              |
| `(parent_path, module, id)` identity  | Per-product `ProductCardStore` survives re-renders by `product.id` |
| Function-valued `attr` as callback    | `on_change` (FilterStore), `on_select` (ProductCardStore)         |
| `handle_info/2` driving state         | Root reacts to `{:filters_changed, ...}` from child closure       |
| `command :name do payload ... end`    | `:select_product`, `:reload_products`, `:change_query`, `:select` |
| `Arbor.State` reusable struct         | `MyApp.MessageState` is mirrored in the messages_store example    |

The runtime concepts proved here:

- **Tree mount under one BEAM process.** All four children live in the same
  page server's mailbox. No per-child process. Reconciliation is by the
  `(parent_path, module, id)` tuple — when `to_state/1` returns the same
  identity tuple across renders, the child socket's assigns survive.
- **Parent → child via attrs (data + functions).** Children receive parent
  state through `attr` declarations. Function-valued attrs are how children
  invoke parent code — there is no `handle_callback` dispatcher, just a
  closure the parent supplies inline through `child(...)`.
- **Child → parent via closure → `handle_info`.** When a child fires its
  callback, the closure runs in the parent's lexical scope and typically
  `send(self(), ...)`s a message that arrives in the parent's
  `handle_info/2`. State mutations flow there.

## Walkthrough scenarios

### 1. Page mounts

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.ProductPageStore,
     %{current_user: %{id: "u1", name: "Ada"}},
     %{transport_pid: self()}}
  )
```

Sequence:

1. Root `mount/1` runs, seeds `:products`, `:selected_product_id`, `:filters`.
2. Root `to_state/1` returns four `child(...)` placeholders + scalar fields.
3. Resolver mounts each child in turn, calling each child's `mount/1`.
4. The runtime computes the wire root, emits one initial `replace ""`
   envelope at `version: 1` covering the entire tree.

The client sees the full state in one push.

### 2. User types in the filter input → server-driven product reload

Client sends `command "change_query"` to the `FilterStore` at path
`["filters"]`:

```elixir
Arbor.Page.Server.command(page, ["filters"], :change_query, %{"query" => "mug"})
```

Sequence:

1. Routing finds `FilterStore` at `["filters"]`. Its `:before_command`
   schema validator runs first.
2. `FilterStore.handle_command(:change_query, ...)` mutates its own
   `:query` assign, then calls `socket.assigns.on_change.(...)` — the
   closure the root supplied through `child(...)`.
3. The closure runs in the root's frame and `send(self(), {:filters_changed, ...})`.
4. The reply lands first (BDR-0009).
5. The page server's `handle_info(:filters_changed, ...)` callback fires
   the catch-all dispatch path. Root re-fetches via `Catalog.list_products/1`
   and replaces `:products` + `:filters`.
6. Render → diff → one envelope. The product list rebuild + filter query
   change ship in the same patch.

### 3. User clicks a product card → selection ripples across siblings

Client sends `command "select"` to a specific card at path
`["products", "prod_2"]`:

```elixir
Arbor.Page.Server.command(page, ["products", "prod_2"], :select, %{})
```

Sequence:

1. The card's `handle_command(:select, ...)` invokes its `on_select`
   callback (when supplied).
2. The closure mutates root state via `send/2` or direct closure capture.
3. After re-render, every sibling card sees an updated `selected:`
   `attr` because their parent's `to_state/1` derives `selected: product.id == socket.assigns.selected_product_id`.
4. JSON Patch emits per-card `replace /selected` ops only for cards
   whose value actually changed (BDR-0014 minimal diff).

### 4. Direct command to the root

```elixir
Arbor.Page.Server.command(page, [], :reload_products, %{})
```

Equivalent end-state to scenario 2 but bypasses the FilterStore — useful
for refresh buttons that don't change the query.

## Run it

```sh
cd examples/product_page_store
mix deps.get
mix compile
iex -S mix
```

Inside iex:

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.ProductPageStore,
     %{current_user: %{id: "u1", name: "Ada"}},
     %{transport_pid: self()}}
  )

flush()  # drains the initial bootstrap envelope

Arbor.Page.Server.command(page, [], :select_product, %{"id" => "prod_2"})

flush()  # drains the post-command patch envelope
```

This example is intentionally **not a test dependency** of the main `arbor`
project. It is documentation that compiles.

## Codegen

This example wires the `:arbor_ts` Mix compiler in `mix.exs`:

```elixir
compilers: Mix.compilers() ++ [:arbor_ts]
```

Every `mix compile` regenerates `priv/codegen/ts/arbor.ts` from the
`state do` blocks. Inspect the output:

```sh
cat priv/codegen/ts/arbor.ts
```

Use `mix compile.arbor_ts --check` (wired into `mix precommit`) to fail
the build when the committed bundle is out of date.
