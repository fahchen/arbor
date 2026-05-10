# product_page_store

Reference implementation of the §Complete Example in `docs/PRD.md`. A root
`MyApp.Stores.ProductPageStore` composes four child stores: header, filters,
product cards, and notifications. Demonstrates:

- function-valued attrs as parent callbacks (`on_change`, `on_select`)
- per-product child mounted by stable `(parent_path, module, id)` identity
- `handle_info/2` driving state mutation when a child fires the parent callback
- a stub `MyApp.Catalog` to keep the example dependency-free

This example is intentionally **not a test dependency** of the main `arbor`
project. It is documentation that compiles.

## Run

```sh
cd examples/product_page_store
mix deps.get
mix compile
```

Or boot one instance and exercise it from `iex`:

```sh
iex -S mix

iex> {:ok, page} = Arbor.Page.Server.start_link(
...>   {MyApp.Stores.ProductPageStore,
...>    %{current_user: %{id: "u1", name: "Ada"}},
...>    %{transport_pid: self()}}
...> )

iex> flush()  # drains the initial bootstrap envelope

iex> Arbor.Page.Server.command(page, [], :select_product, %{id: "prod_2"})

iex> flush()  # drains the post-command patch envelope
```

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
