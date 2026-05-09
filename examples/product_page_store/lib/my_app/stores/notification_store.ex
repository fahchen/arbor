defmodule MyApp.Stores.NotificationStore do
  @moduledoc "Notification badge child."

  use Arbor.Store

  attr :current_user, map(), required: true

  state do
    field :unread_count, integer()
  end

  def mount(socket) do
    {:ok, Arbor.Socket.assign(socket, :unread_count, 0)}
  end

  def to_state(socket) do
    %{unread_count: socket.assigns.unread_count}
  end
end
