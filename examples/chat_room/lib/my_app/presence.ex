defmodule MyApp.Presence do
  @moduledoc """
  Stub presence backend used by the `:online_users` async assign. In a real
  app this would query a tracker process. The synchronous `loading` →
  `ok` flip is still observable on the wire because `assign_async` writes
  `AsyncResult.loading()` synchronously and `AsyncResult.ok(...)` once the
  task finishes — two render cycles regardless of task speed.
  """

  @doc "Returns the canned online-user list for `room_id`."
  @spec list(String.t()) :: [%{id: String.t(), name: String.t()}]
  def list(_room_id) do
    [%{id: "u1", name: "Ada"}, %{id: "u2", name: "Grace"}, %{id: "u3", name: "Linus"}]
  end
end
