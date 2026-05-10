# chat_room

A real-time chat-room page exercising Arbor's full async + stream + PubSub
surface in a single store. Complement to `cart_page` (which is
command-driven and tree-shaped); this one is event-driven and flat.

This example is intentionally **not a test dependency** of the main `arbor`
project. It is documentation that compiles.

## Store tree

```
ChatRoomStore (root, no children)   ← attrs: room_id
```

A single store on purpose — keeps the focus on the async/stream/PubSub
machinery rather than tree composition (`cart_page` covers trees).

## What this example demonstrates

| Arbor primitive                                                  | Where it shows up                                          |
| :--------------------------------------------------------------- | :--------------------------------------------------------- |
| `stream :name, T, item_key:, limit:` slot                        | `:messages` rolling window, server forgets values          |
| `Arbor.AsyncResult.of(T)` field marker                           | `:online_users` discriminated-union surface on the wire    |
| `assign_async/3` for a regular AsyncResult field                 | Loads online users on mount                                |
| `stream_async/3` initial loading flash                           | Seeds `:messages` on mount                                 |
| `start_async/3` + `handle_async/3`                               | `:send_message` command queues a delivery task             |
| `cancel_async/2` from `terminate/2`                              | Abandons in-flight send when the page goes down            |
| `Phoenix.PubSub.subscribe/2` inside `mount/1` (BDR-0005)         | Subscribes to `"room:<room_id>"`                           |
| Catch-all `handle_info/2` dispatch on the page server (BDR-0005) | `{:message_received, msg}` → `stream_insert(at: 0, ...)`   |
| `stream(reset: true)` — silent refresh                           | `:reload` command                                          |
| `stream_async(reset: true)` — loading-flash refresh (BDR-0022)   | `:refresh` command                                         |
| `handle_async/3` exception caught (BDR-0020)                     | The `{:exit, reason}` clause emits a `:failed` send status |
| Variant unions on the wire                                       | `:last_send_status` `:idle` \| `:ok` \| `:failed`          |

## Walkthrough scenarios

### 1. Page mount — concurrent loading flashes

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.ChatRoomStore, %{room_id: "general"}, %{transport_pid: self()}}
  )
```

Sequence:

1. `mount/1` calls `Phoenix.PubSub.subscribe(MyApp.PubSub, "room:general")`.
2. `stream_async(:messages, fun)` synchronously writes `AsyncResult.loading(nil)` to `socket.assigns.messages` and starts a task.
3. `assign_async(:online_users, fun)` does the same for the online-users field.
4. The initial `replace ""` envelope ships — client immediately sees both fields in `loading` status, an empty stream, and an `idle` send status.
5. As each task completes, the runtime writes `AsyncResult.ok(prior, value)` into the corresponding assign and re-renders. `stream_async` additionally seeds the slot with 50 inserts in the same envelope.

The client observes two independent loading flashes resolving on their own schedules.

### 2. New message arrives over PubSub

The `Chat.send_message/2` stub broadcasts on success:

```elixir
Phoenix.PubSub.broadcast(MyApp.PubSub, "room:general", {:message_received, msg})
```

Sequence:

1. `Phoenix.PubSub` delivers `{:message_received, msg}` to every subscriber pid — including this page server.
2. The page server's catch-all `handle_info/2` runs the `:handle_info` hook chain on the root socket and emits `[:arbor, :pubsub, :receive]`.
3. `ChatRoomStore.handle_info({:message_received, msg}, ...)` calls `stream_insert(at: 0, limit: -100)`.
4. Render cycle. `ops` is `[]` (stream-typed paths never appear in `ops` per BDR-0014/0018). One `stream_op` insert ships, plus an evict for the oldest key when the index is full.

### 3. Sending a message — `start_async` + `handle_async/3`

```elixir
Arbor.Page.Server.command(page, [], :send_message, %{"body" => "hello"})
#=> {:ok, %{"queued" => true}}
```

Sequence:

1. The handler calls `start_async(:send_message, fn -> Chat.send_message(...) end)` and immediately replies `%{"queued" => true}`. The reply lands first (BDR-0009) — the client knows the request is in flight.
2. The task runs in the supervised pool. The stub randomly returns `{:ok, %MessageState{}}` or `{:error, :throttled}`.
3. On completion the runtime delivers the result to `handle_async/3`:
   - `{:ok, {:ok, msg}}` → `:last_send_status` becomes `%{type: :ok, id: msg.id}`. Because the stub also broadcasts on success, the new message arrives separately via the PubSub path described in scenario 2.
   - `{:ok, {:error, reason}}` → `:last_send_status` becomes `%{type: :failed, reason: "throttled"}`. No broadcast.
   - `{:exit, reason}` → caught (BDR-0020), emits `[:arbor, :async, :exception]`, `:last_send_status` reports the failure. The page survives.
4. The client sees the variant-union `:last_send_status` flip and (on success) a stream insert in the same or a subsequent envelope.

### 4. Two refresh modes — silent vs. loading flash

```elixir
# Silent: emits a single `reset` op + per-item inserts. AsyncResult is unchanged.
Arbor.Page.Server.command(page, [], :reload, %{})

# Loading flash: re-emits AsyncResult.loading(prior), then ok(prior, true) +
# stream re-seed when the task completes. Use for explicit refresh-with-spinner UX.
Arbor.Page.Server.command(page, [], :refresh, %{})
```

Both behaviors are spec'd in BDR-0022. The client picks the one that fits its UX:

- "Pull-to-refresh" without flicker → `:reload`
- "Reload" button that should show a spinner → `:refresh`

### 5. Page exit cancels the in-flight send

```elixir
GenServer.stop(page)
```

`terminate/2` calls `Arbor.Async.cancel_async(socket, :send_message)`. The runtime kills the tracked task; if no `:send_message` task is currently in flight, the call is a no-op. This prevents the task from outliving the page runtime.

## Run it

```sh
cd examples/chat_room
mix deps.get
mix compile
iex -S mix
```

Inside `iex`:

```elixir
{:ok, page} =
  Arbor.Page.Server.start_link(
    {MyApp.Stores.ChatRoomStore, %{room_id: "general"}, %{transport_pid: self()}}
  )

# Drain a few envelopes — initial mount, online_users, messages async result.
flush()

Arbor.Page.Server.command(page, [], :send_message, %{"body" => "hi"})
#=> {:ok, %{"queued" => true}}

flush()

# External producer simulating another client's broadcast:
msg = %MyApp.MessageState{id: "incoming-1", body: "hello back", sender: "u2"}
Phoenix.PubSub.broadcast(MyApp.PubSub, "room:general", {:message_received, msg})

flush()

Arbor.Page.Server.command(page, [], :refresh, %{})

flush()
```

## Codegen

The example wires the `:arbor_ts` Mix compiler in `mix.exs`:

```elixir
compilers: Mix.compilers() ++ [:arbor_ts]
```

Selected output from `priv/codegen/ts/arbor.ts`:

```ts
export namespace MyApp {
  export type MessageState = {
    id: string
    body: string
    sender: string
  }

  export namespace Stores {
    export type ChatRoomStore = {
      messages: MyApp.MessageState[]
      online_users: AsyncResult<Record<string, unknown>[]>
      last_send_status:
        | { type: "idle" }
        | { type: "ok"; id: string }
        | { type: "failed"; reason: string }
    }

    export namespace ChatRoomStore {
      export type Commands = {
        reload: {}
        refresh: {}
        send_message: { body: string }
      }
    }
  }
}
```

`mix compile.arbor_ts --check` (wired into `mix precommit`) fails the
build when the committed bundle drifts from the source.
