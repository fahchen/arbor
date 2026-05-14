defmodule PollApp.PollSummary do
  @moduledoc """
  Lightweight poll card shown on the dashboard stream.
  """

  use Arbor.State

  state do
    field(:id, String.t())
    field(:title, String.t())
    field(:status, :active | :closed)
    field(:total_votes, integer())
    field(:option_count, integer())
  end
end
