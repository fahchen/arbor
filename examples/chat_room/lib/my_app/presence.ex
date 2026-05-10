defmodule MyApp.Presence do
  @moduledoc """
  Stub presence backend used by the `:online_users` async assign. Returns a
  small canned list after a short delay so `assign_async` lifecycle states
  (`:loading` → `:ok`) are observable on the wire.
  """

  @doc "Returns the canned online-user list for `room_id`."
  @spec list(String.t()) :: [%{id: String.t(), name: String.t()}]
  def list(_room_id) do
    Process.sleep(100)
    [%{id: "u1", name: "Ada"}, %{id: "u2", name: "Grace"}, %{id: "u3", name: "Linus"}]
  end
end
