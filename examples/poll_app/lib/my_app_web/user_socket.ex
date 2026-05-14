defmodule MyAppWeb.AppSession do
  @moduledoc false

  use Arbor.Session,
    roots: [
      MyApp.Stores.DashboardStore,
      MyApp.Stores.PollRoomStore
    ]
end

defmodule MyAppWeb.UserSocket do
  @moduledoc false

  use Arbor.Transport.Socket, session: MyAppWeb.AppSession
end
