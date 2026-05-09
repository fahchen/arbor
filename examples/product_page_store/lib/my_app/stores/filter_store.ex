defmodule MyApp.Stores.FilterStore do
  @moduledoc "Filter child, fires `on_change` callback up to the parent."

  use Arbor.Store

  attr :filters, map(), required: true
  attr :on_change, (map() -> any()), required: true

  state do
    field :query, String.t()
    field :status, String.t()
  end

  command :change_query do
    payload :query, String.t()
  end

  def mount(socket) do
    %{query: query, status: status} = socket.assigns.filters

    socket =
      socket
      |> Arbor.Socket.assign(:query, query)
      |> Arbor.Socket.assign(:status, status)

    {:ok, socket}
  end

  def handle_command(:change_query, %{query: query}, socket) do
    socket = Arbor.Socket.assign(socket, :query, query)

    socket.assigns.on_change.(%{query: query, status: socket.assigns.status})

    {:noreply, socket}
  end

  def to_state(socket) do
    %{query: socket.assigns.query, status: socket.assigns.status}
  end
end
