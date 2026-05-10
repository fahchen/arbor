defmodule MyApp.Stores.CartPageStore do
  @moduledoc """
  Page root. Composes `HeaderStore` plus the `CartStore` widget. Carries no
  business state of its own — every cart mutation routes to `["cart"]`.
  """

  use Arbor.Store

  alias MyApp.Stores.CartStore
  alias MyApp.Stores.HeaderStore

  attr :cart_id, String.t(), required: true
  attr :current_user, map() | nil, default: nil

  state do
    field :header, HeaderStore.state()
    field :cart, CartStore.state()
  end

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

  def mount(socket), do: {:ok, socket}
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end
