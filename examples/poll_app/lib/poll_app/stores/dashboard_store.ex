defmodule PollApp.Stores.DashboardStore do
  @moduledoc """
  Dashboard root store. Renders poll count state and streams poll summaries.
  Demonstrates a stream-driven list page backed by PubSub refreshes.
  """

  use Arbor.Store, root: true

  alias PollApp.DashboardHeader
  alias PollApp.Polls
  alias PollApp.PollSummary

  state do
    field(:header, DashboardHeader.t())
    stream(:polls, PollSummary.t(), item_key: &"poll-#{&1.id}", limit: -20)
  end

  @impl Arbor.Store
  def mount(_params, socket) do
    Phoenix.PubSub.subscribe(PollApp.PubSub, "dashboard")

    {:ok, Arbor.Stream.stream(socket, :polls, Polls.list_summaries(), reset: true)}
  end

  @impl Arbor.Store
  def render(_socket) do
    polls = Polls.list_summaries()
    active = Enum.count(polls, &(&1.status == :active))
    closed = Enum.count(polls, &(&1.status == :closed))

    %{
      header: %DashboardHeader{
        active_count: active,
        closed_count: closed,
        total_count: length(polls)
      },
      polls: stream(:polls)
    }
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  @impl Arbor.Store
  def handle_info({:dashboard_updated, polls}, socket) do
    {:noreply, Arbor.Stream.stream(socket, :polls, polls, reset: true)}
  end
end
