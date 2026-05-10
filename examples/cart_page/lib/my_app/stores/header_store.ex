defmodule MyApp.Stores.HeaderStore do
  @moduledoc "Renders the page header — signed-in state plus user name."

  use Arbor.Store

  attr :current_user, map() | nil, default: nil

  state do
    field :signed_in, boolean()
    field :user_name, String.t() | nil
  end

  def mount(socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> Arbor.Socket.assign(:signed_in, MyApp.Auth.signed_in?(user))
      |> Arbor.Socket.assign(:user_name, user && Map.get(user, :name))

    {:ok, socket}
  end

  def update(params, socket) do
    user = Map.get(params, :current_user)

    socket =
      socket
      |> Arbor.Socket.assign(:signed_in, MyApp.Auth.signed_in?(user))
      |> Arbor.Socket.assign(:user_name, user && Map.get(user, :name))

    {:ok, socket}
  end

  def to_state(socket) do
    %{signed_in: socket.assigns.signed_in, user_name: socket.assigns.user_name}
  end
end
