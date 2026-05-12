defmodule MyApp.Stores.CartPageStore do
  @moduledoc """
  Page root. Composes `HeaderStore` plus the `CartStore` widget. Carries no
  business state of its own — every cart mutation routes to `["cart"]`.
  """

  use Arbor.Store

  alias MyApp.Stores.CartStore
  alias MyApp.Stores.HeaderStore

  attr(:cart_id, String.t(), required: true)
  attr(:current_user, %{id: String.t(), name: String.t()} | nil, default: nil)

  state do
    field(:header, HeaderStore.state())
    field(:cart, CartStore.state())
  end

  @impl Arbor.Store
  def mount(socket) do
    socket =
      Arbor.Socket.assign(
        socket,
        :current_user,
        normalize_current_user(socket.assigns.current_user)
      )

    {:ok, socket}
  end

  @impl Arbor.Store
  def render(socket) do
    %{
      header:
        Arbor.Child.child(HeaderStore,
          id: "header",
          current_user: socket.assigns.current_user
        ),
      cart:
        Arbor.Child.child(CartStore,
          id: "cart",
          cart_id: socket.assigns.cart_id,
          current_user: socket.assigns.current_user
        )
    }
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  defp normalize_current_user(nil), do: nil

  defp normalize_current_user(%{id: id, name: name}) when is_binary(id) and is_binary(name) do
    %{id: id, name: name}
  end

  defp normalize_current_user(%{"id" => id, "name" => name})
       when is_binary(id) and is_binary(name) do
    %{id: id, name: name}
  end

  defp normalize_current_user(_current_user), do: nil
end
