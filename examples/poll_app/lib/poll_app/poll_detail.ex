defmodule PollApp.PollDetail do
  @moduledoc """
  Full poll metadata carried as a plain field on the poll room page.
  """

  use Musubi.State

  state do
    field(:id, String.t())
    field(:title, String.t())
    field(:status, :active | :closed)
    field(:total_votes, integer())
  end
end
