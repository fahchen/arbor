defmodule ChatRoom.OnlineUser do
  @moduledoc """
  Pure structural shape for the `:online_users` async assign on
  `ChatRoom.Stores.ChatRoomStore`. Declared as `Arbor.State` so codegen can
  emit a strongly-typed `OnlineUser` interface that downstream clients
  read without casting.
  """

  use Arbor.State

  state do
    field(:id, String.t())
    field(:name, String.t())
  end
end
