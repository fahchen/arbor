# Session Root Mount Design

Status: implementation draft.

Research notes are kept in `docs/root-connection-research.md`. This document is
the proposed Arbor API and runtime shape.

## Decisions

- Public root stores are declared together in an Arbor session module.
- One Arbor session can mount multiple root stores.
- Session-level `join(params, session, socket)` runs once and prepares shared
  assigns/private data.
- Mounting a root store in the same session calls only that store's
  `mount(params, socket)`.
- All root and child stores in the session can read the shared session data.
- Root stores must opt in with `use Arbor.Store, root: true`.
- Root stores have `mount(params, socket)` and `init(socket)`.
- Child stores have no `mount`; they only use `init(socket)` and `update/2`.
- `Arbor.Reconciler` must not convert string keys to atoms.
- Client root unmount is an Arbor root-unmount control message, not
  `channel.leave()`.

## Session Declaration

An application declares one Arbor session and the root stores that can be mounted
inside it:

```elixir
defmodule MyAppWeb.AppSession do
  use Arbor.Session,
    roots: [
      thermostat: MyApp.Stores.ThermostatStore,
      poll_room: MyApp.Stores.PollRoomStore,
      dashboard: MyApp.Stores.DashboardStore
    ]

  def join(_params, session, socket) do
    current_user =
      session
      |> Map.fetch!("user_id")
      |> MyApp.Accounts.get_user!()

    socket =
      socket
      |> Arbor.Socket.assign(:current_user, current_user)

    {:ok, socket}
  end
end
```

`roots:` is the public exposure list. A root mount is allowed only when both
gates pass:

1. The root is declared in the session `roots:` list.
2. The store module declares `use Arbor.Store, root: true`.

`join/3` is session-level. It runs once when the Arbor session is established,
not once per root store. Any assigns written there are shared by every root
store mounted in the session.

## Endpoint Wiring

The application defines one Arbor Phoenix socket for the session:

```elixir
defmodule MyAppWeb.ArborSocket do
  use Arbor.Transport.Socket, session: MyAppWeb.AppSession
end
```

The Phoenix endpoint mounts that socket:

```elixir
socket "/arbor", MyAppWeb.ArborSocket,
  websocket: [
    connect_info: [
      session: @session_options,
      :peer_data,
      :uri
    ]
  ]
```

Applications should not define an Arbor-specific `PageChannel` just to expose
stores. Arbor owns the channel plumbing; application code owns the session
declaration and the Phoenix socket module that points at it.

## Shared State

Shared application state should be assigned once in `MyAppWeb.AppSession.join/3`.

For example, `current_user` is set here:

```elixir
def join(_params, session, socket) do
  current_user =
    session
    |> Map.fetch!("user_id")
    |> MyApp.Accounts.get_user!()

  {:ok, Arbor.Socket.assign(socket, :current_user, current_user)}
end
```

Every root and child store mounted in that Arbor session can then read:

```elixir
socket.assigns.current_user
```

If the session should reject unauthenticated clients, return an error from
`join/3`:

```elixir
def join(_params, session, socket) do
  case Map.fetch(session, "user_id") do
    {:ok, user_id} ->
      user = MyApp.Accounts.get_user!(user_id)
      {:ok, Arbor.Socket.assign(socket, :current_user, user)}

    :error ->
      {:error, :unauthenticated}
  end
end
```

## Root Store

```elixir
defmodule MyApp.Stores.PollRoomStore do
  use Arbor.Store, root: true

  attr :poll_id, String.t(), required: true

  state do
    field :poll_id, String.t()
  end

  @impl Arbor.Store
  def mount(params, socket) do
    poll_id = Map.fetch!(params, "poll_id")
    current_user = socket.assigns.current_user

    socket =
      socket
      |> Arbor.Socket.assign(:poll_id, poll_id)
      |> Arbor.Socket.assign(:current_user, current_user)

    {:ok, socket}
  end

  @impl Arbor.Store
  def init(socket) do
    {:ok, socket}
  end
end
```

`mount/2` is root-only. It receives string-keyed root mount params and maps known
values to atom-keyed store assigns.

`init/1` runs for every store, root and child. Shared setup belongs there.

## Store Access

Every store should be able to read root params and session data through
`Arbor.Socket`:

```elixir
params = Arbor.Socket.root_params(socket)
session = Arbor.Socket.session(socket)
connect_info = Arbor.Socket.connect_info(socket)
```

Rules:

- Session join params are passed to `Arbor.Session.join/3`; they are not root
  params.
- Root params are per root mount.
- Session data is session-level and shared by every root store.
- Assigns written in `join/3` are shared by every root and child store.
- Transport metadata such as peer data or URI belongs in connect info.

## Runtime Flow

Session join:

1. The client establishes an Arbor session over Arbor's internal transport.
2. Arbor extracts client params, Phoenix session, and preserved connect info.
3. Arbor builds the session `%Arbor.Socket{}`.
4. Arbor calls `MyAppWeb.AppSession.join(params, session, socket)`.
5. If join succeeds, Arbor stores the returned socket as the shared session
   socket.

Root mount inside an existing session:

1. The client asks the session to mount a declared root, for example
   `:poll_room`, with a root id and params.
2. Arbor resolves the root name against the session `roots:` list.
3. Arbor verifies the store declares `use Arbor.Store, root: true`.
4. Arbor derives a root store socket from the shared session socket.
5. Arbor stores root params in the root store socket private data.
6. Arbor calls `root_module.mount(params, socket)`.
7. Arbor validates required attrs using internal atom-keyed assigns only.
8. Arbor calls `root_module.init(socket)`.
9. The normal render, resolve, wire, stream, and patch flow runs.

Mounting another root store in the same Arbor session repeats only the root mount
flow. It does not rerun session `join/3`.

Client messages use the existing Arbor session channel:

```ts
await channel.push("mount", {
  root: "poll_room",
  id: "poll:123",
  params: { poll_id: "123" }
})

await channel.push("command", {
  root_id: "poll:123",
  store_id: [],
  name: "vote",
  payload: { option_id: "a" }
})

await channel.push("unmount", { root_id: "poll:123" })
```

Child store:

1. The reconciler sees a `child/2` placeholder.
2. A new child socket inherits session/connect info private data.
3. A new child runs `init/1`.
4. An existing child runs `update/2`.

## Root Unmount

`root.unmount()` should unmount only that root store:

```ts
await root.unmount()
```

It should send an Arbor control message over the existing session, carrying the
root store identity. It must not call `channel.leave()`.

Leaving the whole Arbor session should tear down every mounted root store in
that session.

Child stores cannot be directly unmounted by the client. They disappear when the
server render output stops including them.

## Reconciler Boundary

`Arbor.Reconciler` should only process internal atom-keyed attrs.

It must not:

- convert string keys to atoms
- know about session join payloads
- know about root mount payloads
- know about session or connect info
- call session `join/3`, root `mount/2`, or store `init/1`

If `%{"poll_id" => "p1"}` arrives as root params, it does not satisfy
`attr :poll_id`. Root `mount/2` must explicitly assign `:poll_id`.

## Implementation Checklist

1. Add `Arbor.Session`.
2. Add `roots:` declaration support to `Arbor.Session.__using__/1`.
3. Add `root: true` support to `Arbor.Store.__using__/1`.
4. Add `__arbor__(:root?)` reflection.
5. Rename all-store `mount/1` to `init/1`.
6. Add root-only `mount/2`.
7. Add socket helpers for root params, session, and connect info.
8. Add internal session transport wiring.
9. Add in-session root mount operation.
10. Remove params-to-attrs mapping from transport join code.
11. Remove string-key conversion from `Arbor.Reconciler`.
12. Add client `root.unmount()` backed by a root-unmount control message.

## Tests

- `Arbor.Session` declares multiple roots.
- session `join/3` receives params, session, and socket.
- session `join/3` assigns are shared by all mounted roots.
- root mount rejects roots not declared by the session.
- root mount rejects stores without `root: true`.
- root `mount/2` receives params and socket.
- root `mount/2` assigns required root attrs.
- root `init/1` runs after root `mount/2`.
- mounting a second root in the same session does not rerun session `join/3`.
- child stores run `init/1` but never `mount/2`.
- child stores can read session/connect info through socket helpers.
- reconciler does not convert string keys to atom keys.
- `root.unmount()` unmounts only that root store.
- leaving the Arbor session tears down all mounted roots.
