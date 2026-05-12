defmodule MyApp.Stores.DashboardStore do
  @moduledoc """
  Dashboard root store. Composes a header child store and streams poll
  summaries. Demonstrates child store composition with a stream-driven
  list page.

  Child stores:
    * `DashboardHeaderStore` ("header") — poll counts
  """

  use Arbor.Store

  alias MyApp.Polls
  alias MyApp.PollSummary
  alias MyApp.Stores.DashboardHeaderStore

  state do
    field(:header, DashboardHeaderStore.state())
    stream(:polls, PollSummary.t(), item_key: &"poll-#{&1.id}", limit: -20)
  end

  @impl Arbor.Store
  def mount(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "dashboard")

    {:ok, Arbor.Stream.stream(socket, :polls, Polls.list_summaries(), reset: true)}
  end

  @impl Arbor.Store
  def render(_socket) do
    polls = Polls.list_summaries()
    active = Enum.count(polls, &(&1.status == :active))
    closed = Enum.count(polls, &(&1.status == :closed))

    %{
      header:
        Arbor.Child.child(DashboardHeaderStore,
          id: "header",
          active_count: active,
          closed_count: closed,
          total_count: length(polls)
        ),
      # Stream-typed field — content flows via stream_ops (BDR-0014/0018).
      polls: []
    }
  end

  @impl Arbor.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}

  @impl Arbor.Store
  def handle_info({:dashboard_updated, polls}, socket) do
    {:noreply, Arbor.Stream.stream(socket, :polls, polls, reset: true)}
  end
end
