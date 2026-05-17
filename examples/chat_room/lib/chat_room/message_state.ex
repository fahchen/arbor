defmodule ChatRoom.MessageState do
  @moduledoc """
  Reusable Musubi.State module describing one chat message. Used as the
  per-item type of the `:messages` stream slot.
  """

  use Musubi.State

  state do
    field(:id, String.t())
    field(:body, String.t())
    field(:sender, String.t())
  end
end
