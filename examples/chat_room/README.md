# chat_room

A real-time chat room example built as a single Musubi store. It demonstrates
async-seeded message streams (`stream_async`), Agent-backed online users via
`assign_async`, PubSub delivery, and `start_async` send handling over the
Phoenix Channel transport. Messages and presence are kept in
application-owned Elixir agents; each room stores and streams only the latest
100 messages. The mount path injects ~1.5s of artificial latency on the
history seed so the `loading → ok` `AsyncResult` transition is visible
client-side.

## Store tree

```text
ChatRoom.Stores.ChatRoomStore (root)
  attrs: room_id
  state:
    messages          AsyncResult<stream of ChatRoom.MessageState>   # stream_async
    current_user      ChatRoom.OnlineUser
    online_users      AsyncResult<list(ChatRoom.OnlineUser)>         # assign_async
    last_send_status  idle | ok | failed                             # start_async
```

## Commands

| Command | Payload | Reply | Behavior |
| :-- | :-- | :-- | :-- |
| `set_name` | `{ name: string }` | `{ ok: boolean, name: string }` | Updates the current user's display name and broadcasts the room's online-user list. |
| `send_message` | `{ body: string }` | `{ queued: boolean }` | Queues message delivery and updates `last_send_status` when the async task completes. |

## Start the example

From the repository root, in two terminals:

```sh
cd examples/chat_room
mix server   # deps.get + run --no-halt
```

```sh
cd examples/chat_room
mix ui       # pnpm install + pnpm dev (in ui/)
```

Open http://localhost:4102.
