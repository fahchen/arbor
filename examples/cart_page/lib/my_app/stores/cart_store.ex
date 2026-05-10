defmodule MyApp.Stores.CartStore do
  @moduledoc """
  Cart widget. Owns the line list, subtotal, and workflow status. Reachable
  from the client at path `["cart"]`.

  Demonstrates the full attach_hook surface:

    * `:authz` on `:before_command` — only `:checkout` requires a signed-in
      user; halt-with-reply emits `[:arbor, :auth, :deny]` (BDR-0008)
    * `:audit` on `:after_command` — writes a structured log entry per command
    * `:persist` on `:after_command` — saves the cart snapshot to ETS via
      `MyApp.Persistence` (the `docs/persistence-pattern.md` recipe)

  Mount loads any previously-persisted lines for the supplied `cart_id`,
  modeling reconnect = recovery (BDR-0015): a fresh page server reads from
  the application's storage layer rather than relying on in-memory carry.
  """

  use Arbor.Store

  require Logger

  alias MyApp.Auth
  alias MyApp.Catalog
  alias MyApp.Persistence
  alias MyApp.Stores.CartLineStore

  attr :cart_id, String.t(), required: true
  attr :current_user, map() | nil, default: nil

  state do
    field :lines, list(CartLineStore.state())
    field :subtotal_cents, integer()
    field :status,
          %{type: :open}
          | %{type: :checking_out}
          | %{type: :checked_out, order_id: String.t()}
  end

  command :add_item do
    payload :sku, String.t()
  end

  command :remove_line do
    payload :id, String.t()
  end

  command(:checkout)

  def mount(socket) do
    lines = Persistence.load_cart(socket.assigns.cart_id)

    socket =
      socket
      |> Arbor.Socket.assign(:lines, lines)
      |> Arbor.Socket.assign(:status, %{type: :open})
      |> Arbor.Lifecycle.attach_hook(:authz, :before_command, &authz/3)
      |> Arbor.Lifecycle.attach_hook(:audit, :after_command, &audit/3)
      |> Arbor.Lifecycle.attach_hook(:persist, :after_command, &persist/3)

    {:ok, socket}
  end

  def handle_command(:add_item, %{"sku" => sku}, socket) do
    case Catalog.fetch(sku) do
      {:ok, product} ->
        next_lines = upsert_line(socket.assigns.lines, product)
        {:noreply, Arbor.Socket.assign(socket, :lines, next_lines)}

      :error ->
        {:reply, %{"error" => "unknown_sku"}, socket}
    end
  end

  def handle_command(:remove_line, %{"id" => id}, socket) do
    next_lines = Enum.reject(socket.assigns.lines, &(&1.id == id))
    {:noreply, Arbor.Socket.assign(socket, :lines, next_lines)}
  end

  def handle_command(:checkout, _payload, socket) do
    order_id = "order-" <> Integer.to_string(System.unique_integer([:positive]))

    socket =
      socket
      |> Arbor.Socket.assign(:lines, [])
      |> Arbor.Socket.assign(:status, %{type: :checked_out, order_id: order_id})

    {:reply, %{"order_id" => order_id}, socket}
  end

  def to_state(socket) do
    %{
      lines:
        for line <- socket.assigns.lines do
          Arbor.Child.child(CartLineStore, id: line.id, line: line)
        end,
      subtotal_cents: subtotal(socket.assigns.lines),
      status: socket.assigns.status
    }
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

  # Save only when `:lines` actually changed during this command cycle.
  # `Arbor.Socket.changed?/2` checks the runtime's mutation-tracking map
  # (BDR-0013). Skipping unchanged commands keeps the persistence layer
  # quiet for read-only handlers.
  defp persist(_command, _payload, socket) do
    if Arbor.Socket.changed?(socket, :lines) do
      Persistence.save_cart(socket.assigns.cart_id, socket.assigns.lines)
    end

    {:cont, socket}
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
end
