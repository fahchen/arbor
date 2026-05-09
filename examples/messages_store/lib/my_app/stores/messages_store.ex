defmodule MyApp.Stores.MessagesStore do
  @moduledoc """
  Reference messages store from §Complete Example in `docs/PRD.md`.

  - `state do` declares one `stream :messages, ...` slot
  - `mount/1` seeds the slot via `stream_async/3` (LV-parity loading flash)
  - `handle_info({:message_received, msg}, ...)` inserts new messages with a
    server-side rolling window via `:limit`
  - `:reload` command refreshes via `stream(reset: true)`

  Demonstrates the full LV-parity stream API plus Arbor's `stream_async/3`
  loading-flash refresh helper.
  """

  use Arbor.Store

  alias MyApp.Chat
  alias MyApp.MessageState

  attr :room_id, :string, required: true

  state do
    stream(:messages, MessageState.t(), item_key: &"msg-#{&1.id}", limit: -100)
  end

  command(:reload)

  def mount(socket) do
    {:ok,
     Arbor.Async.stream_async(socket, :messages, fn ->
       {:ok, Chat.recent(socket.assigns.room_id, 50)}
     end)}
  end

  def handle_command(:reload, _payload, socket) do
    items = Chat.recent(socket.assigns.room_id, 50)
    {:noreply, Arbor.Stream.stream(socket, :messages, items, reset: true)}
  end

  def handle_info({:message_received, %MessageState{} = msg}, socket) do
    {:noreply, Arbor.Stream.stream_insert(socket, :messages, msg, at: 0, limit: -100)}
  end

  def to_state(socket) do
    %{messages: socket.assigns.messages}
  end
end
