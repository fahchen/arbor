# messages_store

Reference implementation of the §Complete Example async + stream excerpt in
`docs/PRD.md`. Boots a single `MyApp.Stores.MessagesStore` page, seeds the
stream slot via `stream_async/3` (initial loading flash), and accepts new
messages through `handle_info(...)`.

This example is intentionally **not a test dependency** of the main `arbor`
project. It is documentation that compiles.

## Run

```sh
cd examples/messages_store
mix deps.get
mix compile
```

Boot one page from `iex`:

```sh
iex -S mix

iex> {:ok, page} = Arbor.Page.Server.start_link(
...>   {MyApp.Stores.MessagesStore, %{room_id: "general"}, %{transport_pid: self()}}
...> )

iex> flush()  # initial bootstrap envelope (loading) + post-async patch (ok)

iex> send(page, {:message_received, %MyApp.MessageState{id: "msg-x", body: "hi", sender: "alice"}})

iex> flush()  # patch envelope with stream insert
```

## Codegen

This example wires the `:arbor_ts` Mix compiler in `mix.exs`:

```elixir
compilers: Mix.compilers() ++ [:arbor_ts]
```

Every `mix compile` regenerates `priv/codegen/ts/arbor.ts` from the
`state do` block. Inspect the output:

```sh
cat priv/codegen/ts/arbor.ts
```

Use `mix compile.arbor_ts --check` (wired into `mix precommit`) to fail
the build when the committed bundle is out of date.
