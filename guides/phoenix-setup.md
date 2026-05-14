# Phoenix Setup

Arbor is Phoenix-first. The runtime uses Phoenix sockets and channels as the
transport, while application modules implement Arbor callbacks.

## Endpoint

Register one Arbor socket in the endpoint:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  socket "/socket", MyAppWeb.UserSocket,
    websocket: true,
    longpoll: false
end
```

If the application needs Phoenix session data in stores, pass the session
through `connect_info`:

```elixir
socket "/socket", MyAppWeb.UserSocket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: false
```

The Arbor socket captures `connect_info[:session]` during connect. Every root
mounted on the same Arbor connection can read it with:

```elixir
Arbor.Socket.session(socket)
```

## Socket Module

Use `Arbor.Socket` instead of `Phoenix.Socket` in application code:

```elixir
defmodule MyAppWeb.UserSocket do
  use Arbor.Socket,
    roots: [
      MyApp.Stores.DashboardStore,
      MyApp.Stores.PollRoomStore
    ]

  @impl Arbor.Socket
  def handle_connect(params, socket) do
    case MyApp.Auth.verify(params["token"]) do
      {:ok, user} -> {:ok, Arbor.Socket.assign(socket, :current_user, user)}
      :error -> :error
    end
  end

  @impl Arbor.Socket
  def handle_join(_params, socket), do: {:ok, socket}
end
```

`use Arbor.Socket` generates the Phoenix socket adapter internally and
registers the `"arbor:*"` channel route. Do not add a separate Arbor channel
entry by hand.

## Callback Responsibilities

`handle_connect/2` runs once when Phoenix establishes the socket. It receives
transport params from the client. Use it for:

- user authentication
- long-lived assigns shared by every Arbor connection and mounted root
- rejecting the socket with `:error` or `{:error, :unauthorized}`

`handle_join/2` runs once when the Arbor connection channel joins. It receives
the connection join params, not root mount params. Use it for:

- workspace or tenant scope checks
- connection-level authorization
- setting assigns shared by every root mounted on that Arbor connection

Root store `mount/2` runs once for each mounted root. It receives the root's
own mount params:

```elixir
@impl Arbor.Store
def mount(%{"poll_id" => poll_id}, socket) do
  socket =
    socket
    |> Arbor.Socket.assign(:poll_id, poll_id)
    |> Arbor.Socket.assign(:current_user, socket.assigns.current_user)

  {:ok, socket}
end
```

## Params, Session, And Connect Info

Use these scopes consistently:

| Scope | Source | Lifetime | Use for |
| :-- | :-- | :-- | :-- |
| connect params | `new Socket("/socket", params: ...)` | Phoenix socket | auth tokens and transport credentials |
| connect info | Phoenix endpoint `connect_info` | Phoenix socket | session, peer data, headers configured by the endpoint |
| session | `connect_info[:session]` | Arbor socket | browser session data shared by mounted roots |
| join params | `connect(socket, topic: ...)` channel join payload | Arbor connection | connection-wide scopes |
| mount params | `connection.mountStore({ module, id, params })` | one root store | business identity such as `poll_id` or `cart_id` |

Child stores do not receive `mount/2`. They run `init/1` and can still read
root params, session, connect info, and inherited assigns from the socket.

## Root Declaration Rules

Only stores declared in `roots: [...]` may be mounted by the client:

```elixir
use Arbor.Socket,
  roots: [
    MyApp.Stores.CartPageStore,
    MyApp.Stores.InboxStore
  ]
```

The client mounts by module string and root id:

```ts
await connection.mountStore({
  module: "MyApp.Stores.CartPageStore",
  id: "cart:current-user",
  params: { cart_id: "current-user" },
})
```

The same root id cannot be mounted twice on one Arbor connection. Unmounting is
also root-scoped:

```ts
await connection.unmountStore("cart:current-user")
```

Child stores are server-owned and cannot be mounted or unmounted directly by
the client.
