defmodule CartPage.Stores.CartLineStore do
  @moduledoc """
  Per-line child store. Owns its own `:qty` mutation and notifies the parent
  via the function-valued `on_qty_change` attr (BDR-0010).

  Demonstrates two patterns in one store:

    * **Child-targeted commands.** `:inc_qty` / `:dec_qty` route to this
      child via the React proxy at `root.cart.lines[i]`. The child mutates
      its own assigns and invokes the parent-supplied `on_qty_change`
      closure, which encapsulates the parent's "what does this mean"
      logic — here, writing through `CartPage.Persistence`. The persistence
      broadcast flows the new line list back through the root and the
      parent recomputes totals on the next render.
    * **Identity-stable reconciliation.** Re-renders by the parent keep the
      same child socket alive as long as
      `(parent_path, CartPage.Stores.CartLineStore, line.id)` keeps appearing.
  """

  use Arbor.Store

  attr(:line, map(), required: true)
  attr(:on_qty_change, (String.t(), integer() -> :ok), required: true)

  state do
    field(:id, String.t())
    field(:sku, String.t())
    field(:name, String.t())
    field(:price_cents, integer())
    field(:qty, integer())
  end

  command :inc_qty do
    reply(%{qty: integer()})
  end

  command :dec_qty do
    reply(%{qty: integer()})
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
  def handle_command(:inc_qty, _payload, socket), do: bump_qty(socket, +1)
  def handle_command(:dec_qty, _payload, socket), do: bump_qty(socket, -1)

  defp bump_qty(socket, delta) do
    next_qty = max(socket.assigns.qty + delta, 1)
    socket = Arbor.Socket.assign(socket, :qty, next_qty)
    :ok = socket.assigns.on_qty_change.(socket.assigns.id, next_qty)
    {:reply, %{"qty" => next_qty}, socket}
  end

  defp mirror_line(socket, line) do
    socket
    |> Arbor.Socket.assign(:id, line.id)
    |> Arbor.Socket.assign(:sku, line.sku)
    |> Arbor.Socket.assign(:name, line.name)
    |> Arbor.Socket.assign(:price_cents, line.price_cents)
    |> Arbor.Socket.assign(:qty, line.qty)
  end
end
