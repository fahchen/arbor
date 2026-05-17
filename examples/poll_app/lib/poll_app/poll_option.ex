defmodule PollApp.PollOption do
  @moduledoc """
  One poll option with live vote count. Used as the per-item type of the
  `:options` stream slot inside `OptionsStore`.
  """

  use Musubi.State

  state do
    field(:id, String.t())
    field(:label, String.t())
    field(:vote_count, integer())
  end
end
