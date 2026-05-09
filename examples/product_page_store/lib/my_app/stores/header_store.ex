defmodule MyApp.Stores.HeaderStore do
  @moduledoc "Header child showing the signed-in user."

  use Arbor.Store

  attr :current_user, map(), required: true

  state do
    field :user_name, String.t()
  end

  def mount(socket) do
    {:ok, Arbor.Socket.assign(socket, :user_name, socket.assigns.current_user.name)}
  end

  def to_state(socket) do
    %{user_name: socket.assigns.user_name}
  end
end
