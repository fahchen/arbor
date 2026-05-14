defmodule MyAppWeb.AppSession do
  @moduledoc false

  use Arbor.Session,
    roots: [
      MyApp.Stores.ChatRoomStore
    ]
end

defmodule MyAppWeb.UserSocket do
  @moduledoc false

  use Arbor.Transport.Socket, session: MyAppWeb.AppSession
end
