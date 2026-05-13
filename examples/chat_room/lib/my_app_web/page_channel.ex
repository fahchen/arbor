defmodule MyAppWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel, stores: [MyApp.Stores.ChatRoomStore]
end
