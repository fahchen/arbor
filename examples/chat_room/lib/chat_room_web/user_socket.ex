defmodule ChatRoomWeb.UserSocket do
  @moduledoc false

  use Musubi.Socket,
    roots: [
      ChatRoom.Stores.ChatRoomStore
    ]
end
