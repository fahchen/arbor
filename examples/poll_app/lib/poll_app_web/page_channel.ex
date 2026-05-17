defmodule PollAppWeb.PageChannel do
  @moduledoc false

  use Musubi.Transport.Channel,
    stores: [
      PollApp.Stores.DashboardStore,
      PollApp.Stores.PollRoomStore
    ]
end
