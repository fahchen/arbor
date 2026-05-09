defmodule MyApp.Stores.ProductPageStore do
  @moduledoc """
  Root store for the product page. Owns header, filters, products list, and
  the notifications badge. Mirrors the §Complete Example in `docs/PRD.md`.
  """

  use Arbor.Store

  alias MyApp.Catalog
  alias MyApp.Stores.{FilterStore, HeaderStore, NotificationStore, ProductCardStore}

  attr :current_user, map(), required: true

  state do
    field :header, HeaderStore.state()
    field :filters, FilterStore.state()
    field :products, list(ProductCardStore.state())
    field :selected_product_id, String.t() | nil
    field :notifications, NotificationStore.state()
  end

  command :select_product do
    payload :id, String.t()
  end

  command(:reload_products)

  def mount(socket) do
    products = Catalog.list_products()

    socket =
      socket
      |> Arbor.Socket.assign(:products, products)
      |> Arbor.Socket.assign(:selected_product_id, nil)
      |> Arbor.Socket.assign(:filters, %{query: "", status: "all"})

    {:ok, socket}
  end

  def handle_command(:select_product, %{id: id}, socket) do
    {:noreply, Arbor.Socket.assign(socket, :selected_product_id, id)}
  end

  def handle_command(:reload_products, _payload, socket) do
    products = Catalog.list_products(socket.assigns.filters)
    {:noreply, Arbor.Socket.assign(socket, :products, products)}
  end

  def handle_info({:filters_changed, filters}, socket) do
    products = Catalog.list_products(filters)

    socket =
      socket
      |> Arbor.Socket.assign(:filters, filters)
      |> Arbor.Socket.assign(:products, products)

    {:noreply, socket}
  end

  def to_state(socket) do
    %{
      header:
        Arbor.Child.child(HeaderStore,
          id: "header",
          current_user: socket.assigns.current_user
        ),
      filters:
        Arbor.Child.child(FilterStore,
          id: "filters",
          filters: socket.assigns.filters,
          on_change: fn payload -> send(self(), {:filters_changed, payload}) end
        ),
      products:
        for product <- socket.assigns.products do
          Arbor.Child.child(ProductCardStore,
            id: product.id,
            product: product,
            selected: product.id == socket.assigns.selected_product_id
          )
        end,
      selected_product_id: socket.assigns.selected_product_id,
      notifications:
        Arbor.Child.child(NotificationStore,
          id: "notifications",
          current_user: socket.assigns.current_user
        )
    }
  end
end
