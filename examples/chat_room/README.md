# chat_room

A real-time chat room example built as a single Arbor store. It demonstrates
streamed messages, Agent-backed online users, PubSub delivery, and async
command handling over the Phoenix Channel transport. Messages and presence are
kept in application-owned Elixir agents; each room stores and streams only the
latest 100 messages.

## Store tree

```text
ChatRoom.Stores.ChatRoomStore (root)
  attrs: room_id
  state:
    messages          stream of ChatRoom.MessageState
    current_user      ChatRoom.OnlineUser
    online_users      AsyncResult<list(ChatRoom.OnlineUser)>
    last_send_status  idle | ok | failed
```

## Commands

| Command | Payload | Reply | Behavior |
| :-- | :-- | :-- | :-- |
| `set_name` | `{ name: string }` | `{ ok: boolean, name: string }` | Updates the current user's display name and broadcasts the room's online-user list. |
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
