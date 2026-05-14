defmodule MyAppWeb.UserSocket do
  @moduledoc false

  use Arbor.Socket,
    roots: [
      MyApp.Stores.ChatRoomStore
    ]
end
