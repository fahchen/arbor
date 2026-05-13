defmodule MyAppWeb.AppSession do
  @moduledoc false

  use Arbor.Session,
    roots: [
      chat_room: MyApp.Stores.ChatRoomStore
    ]
end

defmodule MyAppWeb.UserSocket do
  @moduledoc false

  use Arbor.Transport.Socket, session: MyAppWeb.AppSession
end
