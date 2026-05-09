defmodule MyApp.Stores.ProductCardStore do
  @moduledoc "Per-product card with selection callback fired by `:select`."

  use Arbor.Store

  attr :product, map(), required: true
  attr :selected, boolean(), default: false

  state do
    field :id, String.t()
    field :name, String.t()
    field :selected, boolean()
  end

  command(:select)

  def mount(socket) do
    %{product: product, selected: selected} = socket.assigns

    socket =
      socket
      |> Arbor.Socket.assign(:id, product.id)
      |> Arbor.Socket.assign(:name, product.name)
      |> Arbor.Socket.assign(:selected, selected)

    {:ok, socket}
  end

  def update(params, socket) do
    {:ok, Arbor.Socket.assign(socket, :selected, Map.get(params, :selected, false))}
  end

  def handle_command(:select, _payload, socket) do
    if cb = socket.assigns[:on_select] do
      cb.(%{id: socket.assigns.id})
    end

    {:noreply, socket}
  end

  def to_state(socket) do
    %{
      id: socket.assigns.id,
      name: socket.assigns.name,
      selected: socket.assigns.selected
    }
  end
end
