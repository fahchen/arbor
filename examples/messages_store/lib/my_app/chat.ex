defmodule MyApp.Chat do
  @moduledoc "Stub chat backend that returns canned recent messages."

  alias MyApp.MessageState

  @spec recent(String.t(), pos_integer()) :: [MessageState.t()]
  def recent(_room_id, limit) do
    1..limit
    |> Enum.map(fn n ->
      %MessageState{
        id: "msg-#{n}",
        body: "hello #{n}",
        sender: "user-#{rem(n, 3)}"
      }
    end)
  end
end
