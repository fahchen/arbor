defmodule CartPage.Stores.CartLineStore do
  @moduledoc """
  Per-line leaf store. Render-only: receives the line struct via `attr` and
  mirrors it into typed `state do` output. Demonstrates Arbor's
  identity-stable child reconciliation — the runtime keeps the same child
  socket alive across re-renders as long as `(parent_path, CartPage.Stores.CartLineStore, line.id)`
  keeps appearing in the parent's `render/1`.
  """

  use Arbor.Store

  attr(:line, map(), required: true)

  state do
    field(:id, String.t())
    field(:sku, String.t())
    field(:name, String.t())
    field(:price_cents, integer())
    field(:qty, integer())
  end

  @impl Arbor.Store
  def mount(socket), do: {:ok, mirror_line(socket, socket.assigns.line)}

  @impl Arbor.Store
  def render(socket) do
    %{
      id: socket.assigns.id,
      sku: socket.assigns.sku,
      name: socket.assigns.name,
      price_cents: socket.assigns.price_cents,
      qty: socket.assigns.qty
    }
  end

  @impl Arbor.Store
  def update(params, socket), do: {:ok, mirror_line(socket, params.line)}

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  defp mirror_line(socket, line) do
    socket
    |> Arbor.Socket.assign(:id, line.id)
    |> Arbor.Socket.assign(:sku, line.sku)
    |> Arbor.Socket.assign(:name, line.name)
    |> Arbor.Socket.assign(:price_cents, line.price_cents)
    |> Arbor.Socket.assign(:qty, line.qty)
  end
end
