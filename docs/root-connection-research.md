# Socket Join and Store Mount Research Notes

Status: research notes for `docs/root-connection-design.md`.

## Phoenix

- `Phoenix.Socket.connect/3` receives socket params, a `%Phoenix.Socket{}`, and
  configured `connect_info`. It can authenticate the physical socket and assign
  values into `Phoenix.Socket.assigns`.
  Source: `deps/phoenix/lib/phoenix/socket.ex:205`.
- Phoenix socket assigns from `connect/3` are available to all channels for that
  physical socket.
  Source: `deps/phoenix/lib/phoenix/socket.ex:205`.
- Raw `%Plug.Conn{}` is not handed to channel `join/3`. Phoenix exposes a
  limited `connect_info` map during socket connect.
  Sources: `deps/phoenix/lib/phoenix/endpoint.ex:940`,
  `deps/phoenix/lib/phoenix/socket/transport.ex:455`.
- Endpoint socket config must explicitly request connect info keys such as
  `:peer_data`, `:uri`, `:user_agent`, or `{:session, session_config}`.
  Source: `deps/phoenix/lib/phoenix/endpoint.ex:940`.
- `{:session, session_config}` in `connect_info` requires the endpoint socket
  config and Phoenix's CSRF handling.
  Source: `deps/phoenix/lib/phoenix/endpoint.ex:995`.
- `phx_leave` / `channel.leave()` closes the whole Phoenix channel process with
  `{:shutdown, :left}`.
  Sources: `deps/phoenix/lib/phoenix/channel/server.ex:323`,
  `deps/phoenix/assets/js/phoenix/channel.js:190`.

## LiveView

- Disconnected LiveView render uses `%Plug.Conn{}` and can read conn params,
  conn session, conn assigns, request URL, and other HTTP data.
  Source: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/static.ex:124`.
- LiveView signs session data into rendered HTML and verifies it during the
  connected channel mount.
  Sources: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/static.ex:357`,
  `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/channel.ex:1111`.
- Connected LiveView mount does not receive raw `%Plug.Conn{}`. It receives
  route params, a merged session map, and a LiveView socket.
  Source: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/channel.ex:1164`.
- LiveView modules do not implement a user callback named `connect/3`; they use
  `mount(params, session, socket)`.
  Source: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view.ex:205`.
- LiveView connected mount reads `connect_info[:session]` when configured,
  merges it with the verified signed LiveView session, and passes the merged map
  to `mount/3`.
  Sources: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/channel.ex:1201`,
  `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/channel.ex:1227`.
- LiveView exposes `get_connect_info/2` only during mount.
  Source: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view.ex:1216`.
- LiveView's socket module stores Phoenix `connect_info` in socket private
  during `Phoenix.Socket.connect/3`.
  Source: `/Users/fahchen/GitHub/phoenix_live_view/lib/phoenix_live_view/socket.ex:97`.

## Design Consequences

- Arbor should not expose or depend on raw `%Plug.Conn{}` in connected channel
  code.
- Arbor should keep session separate from connect info.
- Arbor should reserve `connect` terminology for the physical socket handshake.
- Public root exposure should be session-first: an application declares one
  Arbor session with multiple root stores that share session assigns/private
  data.
- Store initialization should use Arbor's own lifecycle names: root-only
  `mount/2` and all-store `init/1`.
- A root-store unmount inside a multi-root Arbor socket cannot use
  `channel.leave()`, because that leaves the whole channel.
