defmodule PollAppWeb.UserSocket do
  @moduledoc false

  use Arbor.Socket,
    roots: [
      PollApp.Stores.DashboardStore,
      PollApp.Stores.PollRoomStore
    ]
end
