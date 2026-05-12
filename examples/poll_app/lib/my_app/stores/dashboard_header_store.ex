defmodule MyApp.Stores.DashboardHeaderStore do
  @moduledoc """
  Simple display child store for the dashboard header. Renders poll counts
  received from the parent via attrs.
  """

  use Arbor.Store

  attr(:active_count, integer(), default: 0)
  attr(:closed_count, integer(), default: 0)
  attr(:total_count, integer(), default: 0)

  state do
    field(:active_count, integer())
    field(:closed_count, integer())
    field(:total_count, integer())
  end

  @impl Arbor.Store
  def mount(socket) do
    {:ok,
     socket
     |> Arbor.Socket.assign(:active_count, socket.assigns.active_count)
     |> Arbor.Socket.assign(:closed_count, socket.assigns.closed_count)
     |> Arbor.Socket.assign(:total_count, socket.assigns.total_count)}
  end

  @impl Arbor.Store
  def render(socket) do
    %{
      active_count: socket.assigns.active_count,
      closed_count: socket.assigns.closed_count,
      total_count: socket.assigns.total_count
    }
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end
