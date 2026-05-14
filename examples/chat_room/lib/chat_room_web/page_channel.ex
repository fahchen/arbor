defmodule ChatRoomWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel, stores: [ChatRoom.Stores.ChatRoomStore]
end
