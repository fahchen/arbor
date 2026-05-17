defmodule PollAppWeb.UserSocket do
  @moduledoc false

  use Musubi.Socket,
    roots: [
      PollApp.Stores.DashboardStore,
      PollApp.Stores.PollRoomStore
    ]
end
