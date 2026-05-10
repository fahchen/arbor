# messages_store

Reference implementation of the §Complete Example async + stream excerpt in
`docs/PRD.md`. A single `MyApp.Stores.MessagesStore` page hosts one chat
room's message history as an LV-parity `stream` slot, seeded asynchronously
on mount.

## What this example demonstrates

| Arbor primitive                      | Where it shows up                                        |
| :----------------------------------- | :------------------------------------------------------- |
| `stream :name, T, opts`              | Declaration inside `state do`                            |
| `stream_async/3` initial loading flash | Inside `mount/1`                                       |
| `stream_insert(at: 0, limit: -100)`  | `handle_info({:message_received, ...})`                  |
| `stream(reset: true)` silent refresh | `handle_command(:reload, ...)`                           |
| `Arbor.AsyncResult` lifecycle        | Surfaced on the wire as `{status: "loading" / "ok"...}`  |
| Application-owned PubSub (BDR-0005)  | External producer `send(page_pid, {:message_received, msg})` |
| `Arbor.State` reusable struct        | `MyApp.MessageState` (id / body / sender)                |

The runtime concepts proved here:

- **Streams forget values server-side.** After flush, the runtime keeps
  only the per-item-key index. The client owns the materialized list.
  This is why a chat history with 100k messages costs constant memory on
  the server.
- **Two refresh modes for streams.** `stream(items, reset: true)` =
  silent refresh (no loading flash, just a `reset` op + new inserts).
  `stream_async(fun, reset: true)` = loading flash (writes
  `AsyncResult.loading(prior)` first, then on success writes
  `AsyncResult.ok(prior, true)` AND seeds the slot in one envelope).
  BDR-0022 documents the split.
- **PubSub is application-owned.** Arbor exposes no `subscribe` macro or
  `broadcast/4` helper. The store calls `Phoenix.PubSub.subscribe(...)`
  directly inside `mount/1` (or accepts plain `send/2` from the page
  itself, as this example does for simplicity). Inbound messages flow
  through `handle_info/2` (BDR-0005).

## Walkthrough scenarios

### 1. Page mounts → loading flash → seeded stream

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.MessagesStore, %{room_id: "general"}, %{transport_pid: self()}}
  )
```

Sequence:

1. Root `mount/1` calls `Arbor.Async.stream_async(socket, :messages, fun)`.
2. The runtime synchronously writes `AsyncResult.loading(nil)` into
   `socket.assigns.messages` and starts the task.
3. The initial render envelope ships immediately — client sees `status:
   "loading"`, an empty stream, and can render a spinner.
4. When `Chat.recent/2` returns, `handle_async/3` writes
   `AsyncResult.ok(prior, true)` AND seeds the stream slot with 50
   inserts in the same envelope.
5. Client receives one patch with both the discriminated-union flip and
   the 50 stream-op inserts.

### 2. New message arrives over PubSub → server inserts at top with rolling window

External producer (your PubSub broadcaster, your test harness, your
`send/2` call) sends:

```elixir
send(page_pid,
  {:message_received,
   %MyApp.MessageState{id: "msg-x", body: "hi", sender: "alice"}})
```

Sequence:

1. Page server's catch-all `handle_info/2` clause runs the
   `:handle_info` hook chain and emits `[:arbor, :pubsub, :receive]`.
2. Root `handle_info({:message_received, msg}, ...)` calls
   `stream_insert(at: 0, limit: -100)`.
3. Runtime queues an `insert` op. If the stream's item-key index is
   already at 100 entries, the insert also queues a matching `delete`
   for the oldest evicted key — both flow in the same envelope.
4. Render cycle runs. JSON Patch `ops` is `[]` (the `messages` slot is
   stream-typed, never appears in `ops` per BDR-0014/0018). Stream ops
   carry the full delta. Envelope still emits because stream_ops is
   non-empty (BDR-0018).

### 3. User clicks "Reload" → silent stream refresh

Client sends `command "reload"`:

```elixir
Arbor.Page.Server.command(page, [], :reload, %{})
```

Sequence:

1. `handle_command(:reload, ...)` calls `stream(socket, :messages,
   fresh_items, reset: true)`.
2. Runtime emits a single `reset` op followed by per-item inserts in the
   same envelope.
3. Client wipes its local stream state and replays the new items. No
   loading flash — `AsyncResult` is unchanged.

Compare to `stream_async(:messages, fun, reset: true)` (not used here)
which would re-emit `AsyncResult.loading(prior)` first for an explicit
refresh-with-spinner UX.

## Run it

```sh
cd examples/messages_store
mix deps.get
mix compile
iex -S mix
```

Inside iex:

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.MessagesStore, %{room_id: "general"}, %{transport_pid: self()}}
  )

flush()  # initial bootstrap envelope (loading) + post-async patch (ok + 50 inserts)

send(page,
  {:message_received,
   %MyApp.MessageState{id: "msg-x", body: "hi", sender: "alice"}})

flush()  # patch envelope with one stream insert at the top

Arbor.Page.Server.command(page, [], :reload, %{})

flush()  # patch envelope: reset op + 50 fresh inserts
```

This example is intentionally **not a test dependency** of the main `arbor`
project. It is documentation that compiles.

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
