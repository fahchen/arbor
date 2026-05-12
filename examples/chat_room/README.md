# chat_room

A real-time chat room example built as a single Arbor store. It demonstrates
streamed messages, async assigns for online users, PubSub delivery, and async
command handling over the Phoenix Channel transport.

## Store tree

```text
MyApp.Stores.ChatRoomStore (root)
  attrs: room_id
  state:
    messages          stream of MyApp.MessageState
    online_users      AsyncResult<list(MyApp.OnlineUser)>
    last_send_status  idle | ok | failed
```

## Commands

| Command | Payload | Reply | Behavior |
| :-- | :-- | :-- | :-- |
| `reload` | `{}` | none | Silently resets and refills the message stream. |
| `refresh` | `{}` | none | Refills the message stream through `stream_async/3`. |
| `send_message` | `{ body: string }` | `{ queued: boolean }` | Queues message delivery and updates `last_send_status` when the async task completes. |

## Start the example

From the repository root:

```sh
cd examples/chat_room
mix deps.get
mix compile
mix run --no-halt
```

In another terminal:

```sh
cd examples/chat_room/ui
pnpm install
pnpm dev
```

Open http://localhost:4102.
