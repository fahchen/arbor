defmodule MyApp.Chat do
  @moduledoc """
  Stub chat backend. In a real app `recent/2` would hit a database or RPC
  service; `send_message/2` would dispatch to a queue / external service.
  Here both return immediately. `send_message/2` randomizes between `:ok`
  (delivery receipt) and `{:error, :throttled}` so `start_async` +
  `handle_async/3` round-tripping is observable on either path.
  """

  alias MyApp.MessageState

  @doc "Returns the `limit` most recent messages for `room_id`."
  @spec recent(String.t(), pos_integer()) :: [MessageState.t()]
  def recent(room_id, limit) when is_binary(room_id) and is_integer(limit) do
    # In a real app: DB query / RPC — wrap the slow call in `stream_async`
    # or `assign_async` so the page server stays responsive.
    1..limit
    |> Enum.map(fn n ->
      %MessageState{
        id: "msg-" <> Integer.to_string(n),
        body: "[#{room_id}] message #{n}",
        sender: "user-" <> Integer.to_string(rem(n, 3))
      }
    end)
  end

  @doc """
  Pretends to send `body` to `room_id`. Half the time returns
  `{:ok, %MessageState{}}`, half returns `{:error, :throttled}` so the
  `handle_async/3` failure path is exercised.
  """
  @spec send_message(String.t(), String.t()) ::
          {:ok, MessageState.t()} | {:error, :throttled}
  def send_message(room_id, body) when is_binary(room_id) and is_binary(body) do
    if :rand.uniform() < 0.5 do
      msg = %MessageState{
        id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        body: body,
        sender: "me"
      }

      Phoenix.PubSub.broadcast(MyApp.PubSub, "room:" <> room_id, {:message_received, msg})

      {:ok, msg}
    else
      {:error, :throttled}
    end
  end
end
