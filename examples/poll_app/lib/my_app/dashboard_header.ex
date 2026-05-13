defmodule MyApp.DashboardHeader do
  @moduledoc """
  Poll count summary rendered at the top of the dashboard.
  """

  use Arbor.State

  state do
    field(:active_count, integer())
    field(:closed_count, integer())
    field(:total_count, integer())
  end
end
