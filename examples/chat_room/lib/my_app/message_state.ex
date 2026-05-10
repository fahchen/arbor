defmodule MyApp.MessageState do
  @moduledoc """
  Reusable Arbor.State module describing one chat message. Used as the
  per-item type of the `:messages` stream slot.
  """

  use Arbor.State

  state do
    field(:id, String.t())
    field(:body, String.t())
    field(:sender, String.t())
  end
end
