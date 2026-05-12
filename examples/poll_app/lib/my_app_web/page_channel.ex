defmodule MyAppWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel,
    stores: [
      MyApp.Stores.DashboardStore,
      MyApp.Stores.PollRoomStore
    ]
end
