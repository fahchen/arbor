defmodule MyApp.Stores.HeaderStore do
  @moduledoc "Renders the page header — signed-in state plus user name."

  use Arbor.Store

  attr :current_user, map() | nil, default: nil

  state do
    field :signed_in, boolean()
    field :user_name, String.t() | nil
  end

  @impl Arbor.Store
  def mount(socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> Arbor.Socket.assign(:signed_in, MyApp.Auth.signed_in?(user))
      |> Arbor.Socket.assign(:user_name, user && Map.get(user, :name))

    {:ok, socket}
  end

  @impl Arbor.Store
  def update(params, socket) do
    user = Map.get(params, :current_user)

    socket =
      socket
      |> Arbor.Socket.assign(:signed_in, MyApp.Auth.signed_in?(user))
      |> Arbor.Socket.assign(:user_name, user && Map.get(user, :name))

    {:ok, socket}
  end

  @impl Arbor.Store
  def render(socket) do
    %{signed_in: socket.assigns.signed_in, user_name: socket.assigns.user_name}
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end
