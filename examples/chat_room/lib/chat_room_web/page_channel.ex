defmodule ChatRoomWeb.PageChannel do
  @moduledoc false

  use Musubi.Transport.Channel, stores: [ChatRoom.Stores.ChatRoomStore]
end
