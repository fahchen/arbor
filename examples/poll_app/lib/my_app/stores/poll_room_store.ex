defmodule MyApp.Stores.PollRoomStore do
  @moduledoc """
  Single-store poll room page. Demonstrates Arbor's stream + async + PubSub
  surface for live voting:

    * `stream :options, PollOption.t()` slot — server forgets values after
      flush; the client owns the materialized list.
    * `Arbor.Stream.stream/4` on root `mount/2` to seed poll options
    * `assign_async/3` for the `:user_vote` AsyncResult field
    * `vote` command with async delivery and BDR-0020 caught-exception path
    * `reset_vote` command to clear a vote
    * `toggle_status` command (sync) to open/close the poll
    * `Phoenix.PubSub.subscribe/2` inside root `mount/2` (BDR-0005) and
      `handle_info/2` dispatch for live cross-user updates
  """

  use Arbor.Store, root: true

  alias MyApp.PollDetail
  alias MyApp.PollOption
  alias MyApp.Polls

  attr(:poll_id, String.t(), required: true)

  @stream_limit -10

  state do
    field(:poll, PollDetail.t())
    stream(:options, PollOption.t(), item_key: &"opt-#{&1.id}", limit: @stream_limit)
    field(:user_vote, Arbor.AsyncResult.of(String.t() | nil))
  end

  command :vote do
    payload(:option_id, String.t())
    reply(%{status: :voted | :already_voted | :closed | :unknown_option})
  end

  command :reset_vote do
    reply(%{status: :reset | :no_vote})
  end

  command :toggle_status do
    reply(%{status: :active | :closed | :not_found})
  end

  @impl Arbor.Store
  def mount(params, socket) do
    poll_id = Map.fetch!(params, "poll_id")
    user_id = new_user_id()
    Phoenix.PubSub.subscribe(MyApp.PubSub, "poll:" <> poll_id)

    socket =
      socket
      |> Arbor.Socket.assign(:poll_id, poll_id)
      |> Arbor.Socket.assign(:user_id, user_id)
      |> Arbor.Socket.assign(:poll, Polls.get_detail(poll_id))
      |> Arbor.Stream.stream(:options, Polls.list_options(poll_id), reset: true)
      |> Arbor.Async.assign_async(:user_vote, fn ->
        {:ok, Polls.get_user_vote(poll_id, user_id)}
      end)

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Render output
  # ---------------------------------------------------------------------------

  @impl Arbor.Store
  def render(socket) do
    %{
      poll: socket.assigns.poll,
      # Stream-typed fields are forced to `[]` on the wire (BDR-0014/0018).
      options: [],
      user_vote: socket.assigns.user_vote
    }
  end

  @spec new_user_id() :: String.t()
  defp new_user_id do
    "user-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  @impl Arbor.Store
  def handle_command(:vote, %{"option_id" => option_id}, socket) do
    poll_id = socket.assigns.poll_id
    user_id = socket.assigns.user_id

    if socket.assigns.poll.status == :closed do
      {:reply, %{"status" => "closed"}, socket}
    else
      {:reply, %{"status" => "voted"},
       Arbor.Async.start_async(socket, :vote, fn ->
         case Polls.vote(poll_id, user_id, option_id) do
           {:ok, :voted} -> {:ok, {:voted, option_id}}
           {:error, reason} -> {:error, reason}
         end
       end)}
    end
  end

  @impl Arbor.Store
  def handle_command(:reset_vote, _payload, socket) do
    poll_id = socket.assigns.poll_id
    user_id = socket.assigns.user_id

    {:reply, %{"status" => "reset"},
     Arbor.Async.start_async(socket, :reset_vote, fn ->
       Polls.reset_vote(poll_id, user_id)
     end)}
  end

  @impl Arbor.Store
  def handle_command(:toggle_status, _payload, socket) do
    poll_id = socket.assigns.poll_id

    case Polls.toggle_status(poll_id) do
      {:ok, new_status} ->
        {:reply, %{"status" => to_string(new_status)}, socket}

      {:error, _} ->
        {:reply, %{"status" => "not_found"}, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Async result routing
  # ---------------------------------------------------------------------------

  @impl Arbor.Store
  def handle_async(:vote, {:ok, {:ok, {:voted, option_id}}}, socket) do
    {:noreply,
     Arbor.Socket.assign(
       socket,
       :user_vote,
       Arbor.AsyncResult.ok(socket.assigns.user_vote, option_id)
     )}
  end

  @impl Arbor.Store
  def handle_async(:vote, {:ok, {:error, reason}}, socket) do
    {:noreply,
     Arbor.Socket.assign(
       socket,
       :user_vote,
       Arbor.AsyncResult.failed(socket.assigns.user_vote, {:error, reason})
     )}
  end

  @impl Arbor.Store
  def handle_async(:vote, {:exit, reason}, socket) do
    {:noreply,
     Arbor.Socket.assign(
       socket,
       :user_vote,
       Arbor.AsyncResult.failed(socket.assigns.user_vote, {:exit, reason})
     )}
  end

  @impl Arbor.Store
  def handle_async(:reset_vote, {:ok, {:ok, :reset}}, socket) do
    {:noreply,
     Arbor.Socket.assign(
       socket,
       :user_vote,
       Arbor.AsyncResult.ok(socket.assigns.user_vote, nil)
     )}
  end

  @impl Arbor.Store
  def handle_async(:reset_vote, {:exit, reason}, socket) do
    {:noreply,
     Arbor.Socket.assign(
       socket,
       :user_vote,
       Arbor.AsyncResult.failed(socket.assigns.user_vote, {:exit, reason})
     )}
  end

  # ---------------------------------------------------------------------------
  # PubSub messages — application-owned (BDR-0005)
  # ---------------------------------------------------------------------------

  @impl Arbor.Store
  def handle_info({:poll_updated, detail, options}, socket) do
    {:noreply,
     socket
     |> Arbor.Socket.assign(:poll, detail)
     |> Arbor.Stream.stream(:options, options, reset: true)}
  end

  @impl Arbor.Store
  def terminate(_reason, socket) do
    Arbor.Async.cancel_async(socket, :vote)
    Arbor.Async.cancel_async(socket, :reset_vote)
    :ok
  end
end
