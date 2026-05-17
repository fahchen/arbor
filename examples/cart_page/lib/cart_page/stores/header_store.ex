defmodule CartPage.Stores.HeaderStore do
  @moduledoc "Renders the page header — signed-in state plus user name."

  use Musubi.Store

  attr(:current_user, %{id: String.t(), name: String.t()} | nil, default: nil)

  state do
    field(:signed_in, boolean())
    field(:user_name, String.t() | nil)
  end

  @impl Musubi.Store
  def mount(socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:signed_in, CartPage.Auth.signed_in?(user))
      |> assign(:user_name, user_name(user))

    {:ok, socket}
  end

  @impl Musubi.Store
  def render(socket) do
    %{signed_in: socket.assigns.signed_in, user_name: socket.assigns.user_name}
  end

  @impl Musubi.Store
  def update(params, socket) do
    user = Map.get(params, :current_user)

    socket =
      socket
      |> assign(:signed_in, CartPage.Auth.signed_in?(user))
      |> assign(:user_name, user_name(user))

    {:ok, socket}
  end

  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  defp user_name(nil), do: nil
  defp user_name(%{name: name}) when is_binary(name), do: name
  defp user_name(_user), do: nil
end
