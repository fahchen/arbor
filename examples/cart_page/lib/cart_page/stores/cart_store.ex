defmodule CartPage.Stores.CartStore do
  @moduledoc """
  Cart widget. Owns the line list, subtotal, and workflow status. Reachable
  from the client at path `["cart"]`.

  Demonstrates the full attach_hook surface:

    * `:authz` on `:before_command` — only `:checkout` requires a signed-in
      user; halt-with-reply emits `[:arbor, :auth, :deny]` (BDR-0008)
    * `:audit` on `:after_command` — writes a structured log entry per command
    * storage writes through `CartPage.Persistence` — every mutation uses the
      latest shared snapshot and broadcasts it to other tabs

  The root store loads and subscribes to the shared cart snapshot, then passes
  it through `:cart_lines`. That models reconnect = recovery (BDR-0015) while
  keeping already-open tabs synchronized.
  """

  use Arbor.Store

  require Logger

  alias CartPage.Auth
  alias CartPage.Catalog
  alias CartPage.Persistence
  alias CartPage.Stores.CartLineStore

  attr(:cart_id, String.t(), required: true)

  attr(
    :cart_lines,
    list(%{
      id: String.t(),
      sku: String.t(),
      name: String.t(),
      price_cents: integer(),
      qty: integer()
    }),
    required: true
  )

  attr(:current_user, %{id: String.t(), name: String.t()} | nil, default: nil)

  state do
    field(:lines, list(CartLineStore.state()))
    field(:total_units, integer())
    field(:subtotal_cents, integer())

    field(
      :status,
      %{type: :open}
      | %{type: :checking_out}
      | %{type: :checked_out, order_id: String.t()}
    )
  end

  command :add_item do
    payload(:sku, String.t())
  end

  command :remove_line do
    payload(:id, String.t())
  end

  command(:checkout)

  @impl Arbor.Store
  def mount(socket) do
    socket =
      socket
      |> assign(:lines, socket.assigns.cart_lines)
      |> assign(:status, %{type: :open})
      |> assign(:on_qty_change, build_on_qty_change(socket.assigns.cart_id))
      |> attach_hook(:authz, :before_command, &authz/3)
      |> attach_hook(:audit, :after_command, &audit/3)

    {:ok, socket}
  end

  @impl Arbor.Store
  def update(params, socket) do
    socket =
      socket
      |> assign(params)
      |> assign(:lines, params.cart_lines)
      |> reopen_if_lines_present(params.cart_lines)

    {:ok, socket}
  end

  @impl Arbor.Store
  def render(socket) do
    %{
      lines:
        for line <- socket.assigns.lines do
          child(CartLineStore,
            id: line.id,
            line: line,
            on_qty_change: socket.assigns.on_qty_change
          )
        end,
      total_units: total_units(socket.assigns.lines),
      subtotal_cents: subtotal(socket.assigns.lines),
      status: socket.assigns.status
    }
  end

  # Built once in `mount/1` and parked under `:on_qty_change` so every
  # `render/1` passes the same closure reference to each child. A fresh
  # closure per render would dirty-mark every child's `:on_qty_change`
  # assign and defeat BDR-0013 memoization.
  #
  # Child line stores call this after mutating their own `:qty`. The
  # write goes through the shared `Persistence` snapshot, whose
  # `{:cart_snapshot, ...}` broadcast re-flows `:cart_lines` through the
  # root and back into this store's `update/2`, recomputing totals on
  # the next render.
  @spec build_on_qty_change(String.t()) :: (String.t(), integer() -> :ok)
  defp build_on_qty_change(cart_id) do
    fn id, qty ->
      Persistence.update_cart(cart_id, fn lines ->
        Enum.map(lines, fn
          %{id: ^id} = line -> %{line | qty: qty}
          line -> line
        end)
      end)

      :ok
    end
  end

  @impl Arbor.Store
  def handle_command(:add_item, %{"sku" => sku}, socket) do
    case Catalog.fetch(sku) do
      {:ok, product} ->
        next_lines =
          Persistence.update_cart(socket.assigns.cart_id, fn lines ->
            upsert_line(lines, product)
          end)

        socket =
          socket
          |> assign(:lines, next_lines)
          |> assign(:status, %{type: :open})

        {:noreply, socket}

      :error ->
        {:reply, %{"error" => "unknown_sku"}, socket}
    end
  end

  @impl Arbor.Store
  def handle_command(:remove_line, %{"id" => id}, socket) do
    next_lines =
      Persistence.update_cart(socket.assigns.cart_id, fn lines ->
        Enum.reject(lines, &(&1.id == id))
      end)

    {:noreply, assign(socket, :lines, next_lines)}
  end

  @impl Arbor.Store
  def handle_command(:checkout, _payload, socket) do
    order_id = "order-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok = Persistence.save_cart(socket.assigns.cart_id, [])

    socket =
      socket
      |> assign(:lines, [])
      |> assign(:status, %{type: :checked_out, order_id: order_id})

    {:reply, %{"order_id" => order_id}, socket}
  end

  # ---------------------------------------------------------------------------
  # Hooks
  # ---------------------------------------------------------------------------

  # Only `:checkout` is gated. `:add_item` / `:remove_line` allowed for guests.
  defp authz(:checkout, _payload, socket) do
    if Auth.signed_in?(socket.assigns.current_user) do
      {:cont, socket}
    else
      {:halt, %{"error" => "must_sign_in"}, socket}
    end
  end

  defp authz(_command, _payload, socket), do: {:cont, socket}

  defp audit(command_name, payload, socket) do
    Logger.info(
      "[audit] cart=#{socket.assigns.cart_id} command=#{command_name} payload=#{inspect(payload)}"
    )

    {:cont, socket}
  end

  defp reopen_if_lines_present(socket, []), do: socket

  defp reopen_if_lines_present(socket, _lines) do
    case socket.assigns.status do
      %{type: :checked_out} -> assign(socket, :status, %{type: :open})
      _status -> socket
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp upsert_line(lines, product) do
    case Enum.split_with(lines, &(&1.sku == product.sku)) do
      {[existing], rest} ->
        rest ++ [%{existing | qty: existing.qty + 1}]

      {[], _rest} ->
        line = %{
          id: product.sku <> "-" <> Integer.to_string(System.unique_integer([:positive])),
          sku: product.sku,
          name: product.name,
          price_cents: product.price_cents,
          qty: 1
        }

        lines ++ [line]
    end
  end

  defp subtotal(lines) do
    Enum.reduce(lines, 0, fn line, acc -> acc + line.price_cents * line.qty end)
  end

  defp total_units(lines) do
    Enum.reduce(lines, 0, fn line, acc -> acc + line.qty end)
  end
end
