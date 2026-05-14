defmodule PollAppWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel,
    stores: [
      PollApp.Stores.DashboardStore,
      PollApp.Stores.PollRoomStore
    ]
end
