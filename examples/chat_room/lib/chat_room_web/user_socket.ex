defmodule ChatRoomWeb.UserSocket do
  @moduledoc false

  use Arbor.Socket,
    roots: [
      ChatRoom.Stores.ChatRoomStore
    ]
end
