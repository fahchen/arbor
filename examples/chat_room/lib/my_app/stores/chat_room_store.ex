defmodule MyApp.Stores.ChatRoomStore do
  @moduledoc """
  Single-store chat-room page. Demonstrates Arbor's full async + stream +
  PubSub surface in one module:

    * `stream :messages, MessageState.t()` slot — server forgets values
      after flush; only the per-stream slot config (item_key fn, limit,
      ref counter) survives on the socket. The client owns the
      materialized list.
    * `stream_async/3` on `mount/1` for the initial loading flash
    * `assign_async/3` for the `:online_users` AsyncResult field
    * `start_async/3` + `handle_async/3` for the optimistic `:send_message`
      flow with delivery receipts and the BDR-0020 caught-exception path
    * `cancel_async/2` from `terminate/2` to abandon any in-flight send
    * `Phoenix.PubSub.subscribe/2` inside `mount/1` (BDR-0005:
      application-owned PubSub) and `handle_info/2` dispatch
    * `:reload` command via `stream(reset: true)` (silent refresh)
    * `:refresh` command via `stream_async(reset: true)` (loading flash
      refresh, BDR-0022)
  """

  use Arbor.Store

  alias MyApp.Chat
  alias MyApp.MessageState
  alias MyApp.Presence

  attr :room_id, String.t(), required: true

  state do
    stream(:messages, MessageState.t(), item_key: &"msg-#{&1.id}", limit: -100)
    field :online_users, Arbor.AsyncResult.of(list(map()))
    field :last_send_status, %{type: :idle} | %{type: :ok, id: String.t()} | %{type: :failed, reason: String.t()}
  end

  command(:reload)

  command(:refresh)

  command :send_message do
    payload :body, String.t()
  end

  @impl Arbor.Store
  def mount(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "room:" <> socket.assigns.room_id)

    room_id = socket.assigns.room_id

    socket =
      socket
      |> Arbor.Socket.assign(:last_send_status, %{type: :idle})
      |> Arbor.Async.stream_async(:messages, fn -> {:ok, Chat.recent(room_id, 50)} end)
      |> Arbor.Async.assign_async(:online_users, fn -> {:ok, Presence.list(room_id)} end)

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  # Silent stream refresh — no loading flash. Emits a `reset` op + per-item
  # inserts in the same envelope.
  @impl Arbor.Store
  def handle_command(:reload, _payload, socket) do
    items = Chat.recent(socket.assigns.room_id, 50)
    {:noreply, Arbor.Stream.stream(socket, :messages, items, reset: true)}
  end

  # Loading-flash stream refresh — re-emits AsyncResult.loading(prior) and
  # then writes ok(prior, true) when the task completes (BDR-0022).
  @impl Arbor.Store
  def handle_command(:refresh, _payload, socket) do
    room_id = socket.assigns.room_id

    {:noreply,
     Arbor.Async.stream_async(socket, :messages, fn -> {:ok, Chat.recent(room_id, 50)} end,
       reset: true
     )}
  end

  # `start_async/3` kicks off a fire-and-forget send. The result routes to
  # `handle_async/3` below — `socket.assigns` is NOT mutated by start_async
  # itself, only by what handle_async writes.
  @impl Arbor.Store
  def handle_command(:send_message, %{"body" => body}, socket) do
    room_id = socket.assigns.room_id

    {:reply, %{"queued" => true},
     Arbor.Async.start_async(socket, :send_message, fn -> Chat.send_message(room_id, body) end)}
  end

  # ---------------------------------------------------------------------------
  # Async result routing
  # ---------------------------------------------------------------------------

  # `:ok` and `:error` are application-level outcomes the task fun returned.
  # `:exit` is the task-exit path (task crashed / killed) — the runtime
  # delivers it to `handle_async/3` and emits `[:arbor, :async, :stop]` with
  # `status: :failed`. BDR-0020 (`[:arbor, :async, :exception]`) covers a
  # different case: the `handle_async/3` clause itself raising — the runtime
  # catches that and the page survives. This example does not raise from
  # `handle_async/3`.
  @impl Arbor.Store
  def handle_async(:send_message, {:ok, {:ok, %MessageState{id: id}}}, socket) do
    {:noreply, Arbor.Socket.assign(socket, :last_send_status, %{type: :ok, id: id})}
  end

  @impl Arbor.Store
  def handle_async(:send_message, {:ok, {:error, reason}}, socket) do
    status = %{type: :failed, reason: Atom.to_string(reason)}
    {:noreply, Arbor.Socket.assign(socket, :last_send_status, status)}
  end

  @impl Arbor.Store
  def handle_async(:send_message, {:exit, reason}, socket) do
    status = %{type: :failed, reason: inspect(reason)}
    {:noreply, Arbor.Socket.assign(socket, :last_send_status, status)}
  end

  # ---------------------------------------------------------------------------
  # PubSub messages — application-owned (BDR-0005)
  # ---------------------------------------------------------------------------

  @impl Arbor.Store
  def handle_info({:message_received, %MessageState{} = msg}, socket) do
    {:noreply, Arbor.Stream.stream_insert(socket, :messages, msg, at: 0, limit: -100)}
  end

  # ---------------------------------------------------------------------------
  # Render output
  # ---------------------------------------------------------------------------

  @impl Arbor.Store
  def render(socket) do
    %{
      # Stream-typed fields are forced to `[]` on the wire by `Arbor.Wire`
      # (BDR-0014/0018) — content flows via stream_ops. `socket.assigns.messages`
      # also holds an internal AsyncResult flag after `stream_async`, so we
      # return a literal `[]` here to match the actual on-wire shape.
      messages: [],
      online_users: socket.assigns.online_users,
      last_send_status: socket.assigns.last_send_status
    }
  end

  # Cancel any in-flight send when the page goes down so the task does not
  # outlive the runtime. `cancel_async/2` is a no-op when the name is not
  # tracked.
  @impl Arbor.Store
  def terminate(_reason, socket) do
    Arbor.Async.cancel_async(socket, :send_message)
    :ok
  end
end
