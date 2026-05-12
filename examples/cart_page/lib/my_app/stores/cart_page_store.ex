defmodule MyApp.Stores.CartPageStore do
  @moduledoc """
  Page root. Composes `HeaderStore` plus the `CartStore` widget. Carries no
  business state of its own — every cart mutation routes to `["cart"]`.
  """

  use Arbor.Store

  alias MyApp.Persistence
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
    :ok = Persistence.subscribe_cart(socket.assigns.cart_id)

    socket =
      socket
      |> Arbor.Socket.assign(:cart_lines, Persistence.load_cart(socket.assigns.cart_id))
      |> Arbor.Socket.assign(:current_user, normalize_current_user(socket.assigns.current_user))

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
          cart_lines: socket.assigns.cart_lines,
          current_user: socket.assigns.current_user
        )
    }
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  @impl Arbor.Store
  def handle_info({:cart_snapshot, cart_id, lines}, socket)
      when is_binary(cart_id) and is_list(lines) do
    if cart_id == socket.assigns.cart_id do
      {:noreply, Arbor.Socket.assign(socket, :cart_lines, lines)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
