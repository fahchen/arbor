defmodule MyApp.Polls do
  @moduledoc """
  Agent-backed in-memory poll backend for the example.

  Stores multiple polls. Each poll tracks its options and per-user votes.
  Broadcasts changes via PubSub so all connected page servers stay in sync.
  """

  use Agent

  alias MyApp.PollDetail
  alias MyApp.PollOption
  alias MyApp.PollSummary

  @typep poll_id() :: String.t()
  @typep option_id() :: String.t()
  @typep user_id() :: String.t()

  @typep option() :: %{
          id: option_id(),
          label: String.t(),
          vote_count: non_neg_integer()
        }

  @typep poll() :: %{
          title: String.t(),
          status: :active | :closed,
          options: %{option_id() => option()},
          votes: %{user_id() => option_id()}
        }

  @typep state() :: %{poll_id() => poll()}

  @doc """
  Starts the example poll store seeded with demo polls.

  ## Examples

      children = [MyApp.Polls]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> seed_polls() end, name: __MODULE__)
  end

  @doc """
  Returns poll summaries for the dashboard stream.

  ## Examples

      MyApp.Polls.list_summaries()
      #=> [%MyApp.PollSummary{...}, ...]
  """
  @spec list_summaries() :: [PollSummary.t()]
  def list_summaries do
    Agent.get(__MODULE__, fn polls ->
      polls
      |> Enum.map(fn {id, poll} -> to_poll_summary(id, poll) end)
      |> Enum.sort_by(& &1.title)
    end)
  end

  @doc """
  Returns the poll detail struct for `poll_id`, or nil.

  ## Examples

      MyApp.Polls.get_detail("demo-poll")
      #=> %MyApp.PollDetail{...}
  """
  @spec get_detail(poll_id()) :: PollDetail.t() | nil
  def get_detail(poll_id) when is_binary(poll_id) do
    Agent.get(__MODULE__, fn polls ->
      case Map.get(polls, poll_id) do
        nil -> nil
        poll -> to_poll_detail(poll_id, poll)
      end
    end)
  end

  @doc """
  Returns the sorted option list for `poll_id`.

  ## Examples

      MyApp.Polls.list_options("demo-poll")
      #=> [%MyApp.PollOption{...}, ...]
  """
  @spec list_options(poll_id()) :: [PollOption.t()]
  def list_options(poll_id) when is_binary(poll_id) do
    Agent.get(__MODULE__, fn polls ->
      case Map.get(polls, poll_id) do
        nil -> []
        poll -> poll.options |> Map.values() |> Enum.sort_by(& &1.id)
      end
    end)
  end

  @doc """
  Returns the option id the user voted for, or nil.

  ## Examples

      MyApp.Polls.get_user_vote("demo-poll", "user-1")
      #=> "opt-1"
  """
  @spec get_user_vote(poll_id(), user_id()) :: option_id() | nil
  def get_user_vote(poll_id, user_id) when is_binary(poll_id) and is_binary(user_id) do
    Agent.get(__MODULE__, fn polls ->
      polls |> Map.get(poll_id, %{}) |> Map.get(:votes, %{}) |> Map.get(user_id)
    end)
  end

  @doc """
  Casts (or changes) a vote for `option_id`. Broadcasts the updated poll.

  ## Examples

      MyApp.Polls.vote("demo-poll", "user-1", "opt-2")
      #=> {:ok, :voted}
  """
  @spec vote(poll_id(), user_id(), option_id()) :: {:ok, :voted} | {:error, :closed | :unknown_option}
  def vote(poll_id, user_id, option_id)

  def vote(poll_id, user_id, option_id) do
    case Agent.get(__MODULE__, fn polls ->
      with %{status: :active} <- Map.get(polls, poll_id, %{status: :closed}) do
        :ok
      end
    end) do
      :ok ->
        result =
          Agent.get_and_update(__MODULE__, fn polls ->
            poll = Map.get(polls, poll_id)

            cond do
              is_nil(poll) ->
                {{:error, :unknown_option}, polls}

              poll.status == :closed ->
                {{:error, :closed}, polls}

              not Map.has_key?(poll.options, option_id) ->
                {{:error, :unknown_option}, polls}

              true ->
                poll = remove_prior_vote(poll, user_id)
                poll = add_vote(poll, user_id, option_id)
                {{:ok, :voted}, Map.put(polls, poll_id, poll)}
            end
          end)

        broadcast(poll_id)
        broadcast_dashboard()
        result

      _ ->
        {:error, :closed}
    end
  end

  @doc """
  Removes a user's vote. Broadcasts the updated poll.

  ## Examples

      MyApp.Polls.reset_vote("demo-poll", "user-1")
      #=> {:ok, :reset}
  """
  @spec reset_vote(poll_id(), user_id()) :: {:ok, :reset}
  def reset_vote(poll_id, user_id) when is_binary(poll_id) and is_binary(user_id) do
    Agent.update(__MODULE__, fn polls ->
      poll = Map.get(polls, poll_id, %{})
      poll = remove_prior_vote(poll, user_id)
      Map.put(polls, poll_id, poll)
    end)

    broadcast(poll_id)
    broadcast_dashboard()
    {:ok, :reset}
  end

  @doc """
  Toggles poll status between active and closed.

  ## Examples

      MyApp.Polls.toggle_status("demo-poll")
      #=> {:ok, :closed}
  """
  @spec toggle_status(poll_id()) :: {:ok, :active | :closed} | {:error, :not_found}
  def toggle_status(poll_id) when is_binary(poll_id) do
    result =
      Agent.get_and_update(__MODULE__, fn polls ->
        case Map.get(polls, poll_id) do
          nil ->
            {{:error, :not_found}, polls}

          poll ->
            new_status = if poll.status == :active, do: :closed, else: :active
            {{:ok, new_status}, Map.put(polls, poll_id, %{poll | status: new_status})}
        end
      end)

    broadcast(poll_id)
    broadcast_dashboard()
    result
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec seed_polls() :: state()
  defp seed_polls do
    %{
      "food-poll" => %{
        title: "What should we eat?",
        status: :active,
        options: options(%{
          "tacos" => "Tacos",
          "pizza" => "Pizza",
          "sushi" => "Sushi",
          "ramen" => "Ramen"
        }),
        votes: %{}
      },
      "lang-poll" => %{
        title: "Favorite language?",
        status: :active,
        options: options(%{
          "elixir" => "Elixir",
          "rust" => "Rust",
          "typescript" => "TypeScript"
        }),
        votes: %{}
      },
      "editor-poll" => %{
        title: "Best code editor?",
        status: :active,
        options: options(%{
          "vscode" => "VS Code",
          "neovim" => "Neovim",
          "helix" => "Helix",
          "zed" => "Zed"
        }),
        votes: %{}
      },
      "work-poll" => %{
        title: "Remote or office?",
        status: :active,
        options: options(%{
          "remote" => "Remote",
          "office" => "Office",
          "hybrid" => "Hybrid"
        }),
        votes: %{}
      },
      "coffee-poll" => %{
        title: "Coffee or tea?",
        status: :active,
        options: options(%{
          "coffee" => "Coffee",
          "tea" => "Tea",
          "neither" => "Neither — water"
        }),
        votes: %{}
      },
      "season-poll" => %{
        title: "Favorite season?",
        status: :active,
        options: options(%{
          "spring" => "Spring",
          "summer" => "Summer",
          "autumn" => "Autumn",
          "winter" => "Winter"
        }),
        votes: %{}
      }
    }
  end

  @spec options(%{String.t() => String.t()}) :: %{String.t() => option()}
  defp options(map) do
    Map.new(map, fn {id, label} -> {id, %{id: id, label: label, vote_count: 0}} end)
  end

  @spec to_poll_summary(poll_id(), poll()) :: PollSummary.t()
  defp to_poll_summary(poll_id, poll) do
    total = poll.options |> Map.values() |> Enum.map(& &1.vote_count) |> Enum.sum()

    %PollSummary{
      id: poll_id,
      title: poll.title,
      status: poll.status,
      total_votes: total,
      option_count: map_size(poll.options)
    }
  end

  @spec to_poll_detail(poll_id(), poll()) :: PollDetail.t()
  defp to_poll_detail(poll_id, poll) do
    total = poll.options |> Map.values() |> Enum.map(& &1.vote_count) |> Enum.sum()

    %PollDetail{
      id: poll_id,
      title: poll.title,
      status: poll.status,
      total_votes: total
    }
  end

  @spec remove_prior_vote(poll(), user_id()) :: poll()
  defp remove_prior_vote(poll, user_id) do
    case Map.get(poll.votes, user_id) do
      nil ->
        poll

      prior_option_id ->
        poll
        |> update_in([Access.key!(:options), prior_option_id, :vote_count], &max(0, &1 - 1))
        |> put_in([Access.key!(:votes), user_id], nil)
    end
  end

  @spec add_vote(poll(), user_id(), option_id()) :: poll()
  defp add_vote(poll, user_id, option_id) do
    poll
    |> update_in([Access.key!(:options), option_id, :vote_count], &(&1 + 1))
    |> put_in([Access.key!(:votes), user_id], option_id)
  end

  @spec broadcast(poll_id()) :: :ok
  defp broadcast(poll_id) do
    detail = get_detail(poll_id)
    options = list_options(poll_id)

    if detail do
      Phoenix.PubSub.broadcast(MyApp.PubSub, "poll:" <> poll_id, {:poll_updated, detail, options})
    end

    :ok
  end

  @spec broadcast_dashboard() :: :ok
  defp broadcast_dashboard do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "dashboard", {:dashboard_updated, list_summaries()})
  end
end
