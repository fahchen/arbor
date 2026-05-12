defmodule MyApp.Stores.HeaderStore do
  @moduledoc "Renders the page header — signed-in state plus user name."

  use Arbor.Store

  attr(:current_user, %{id: String.t(), name: String.t()} | nil, default: nil)

  state do
    field(:signed_in, boolean())
    field(:user_name, String.t() | nil)
  end

  @impl Arbor.Store
  def mount(socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> Arbor.Socket.assign(:signed_in, MyApp.Auth.signed_in?(user))
      |> Arbor.Socket.assign(:user_name, user_name(user))

    {:ok, socket}
  end

  @impl Arbor.Store
  def render(socket) do
    %{signed_in: socket.assigns.signed_in, user_name: socket.assigns.user_name}
  end

  @impl Arbor.Store
  def update(params, socket) do
    user = Map.get(params, :current_user)

    socket =
      socket
      |> Arbor.Socket.assign(:signed_in, MyApp.Auth.signed_in?(user))
      |> Arbor.Socket.assign(:user_name, user_name(user))

    {:ok, socket}
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  defp user_name(nil), do: nil
  defp user_name(%{name: name}) when is_binary(name), do: name
  defp user_name(_user), do: nil
end
