defmodule MyApp.Presence do
  @moduledoc """
  Agent-backed presence registry for the chat room example.

  The registry is intentionally application-owned. Stores subscribe to room
  PubSub topics and update their own assigns when this module broadcasts
  presence changes.
  """

  use Agent

  alias MyApp.OnlineUser

  @typep room_id() :: String.t()
  @typep user_id() :: String.t()
  @typep room_users() :: %{room_id() => %{user_id() => OnlineUser.t()}}

  @doc """
  Starts the example presence registry.

  ## Examples

      children = [MyApp.Presence]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc """
  Adds a user to a room and broadcasts the updated room list.

  ## Examples

      MyApp.Presence.join("general", "u1", "Ada")
      #=> %MyApp.OnlineUser{id: "u1", name: "Ada"}
  """
  @spec join(String.t(), String.t(), String.t()) :: OnlineUser.t()
  def join(room_id, user_id, name)
      when is_binary(room_id) and is_binary(user_id) and is_binary(name) do
    user = %OnlineUser{id: user_id, name: name}
    Agent.update(__MODULE__, &put_user(&1, room_id, user))
    broadcast(room_id)
    user
  end

  @doc """
  Renames a user in a room and broadcasts the updated room list.

  ## Examples

      MyApp.Presence.update_name("general", "u1", "Grace")
      #=> %MyApp.OnlineUser{id: "u1", name: "Grace"}
  """
  @spec update_name(String.t(), String.t(), String.t()) :: OnlineUser.t()
  def update_name(room_id, user_id, name)
      when is_binary(room_id) and is_binary(user_id) and is_binary(name) do
    user = %OnlineUser{id: user_id, name: name}
    Agent.update(__MODULE__, &put_user(&1, room_id, user))
    broadcast(room_id)
    user
  end

  @doc """
  Removes a user from a room and broadcasts the updated room list.

  ## Examples

      MyApp.Presence.leave("general", "u1")
      #=> :ok
  """
  @spec leave(String.t(), String.t()) :: :ok
  def leave(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    Agent.update(__MODULE__, &delete_user(&1, room_id, user_id))
    broadcast(room_id)
  end

  @doc """
  Returns the current online users for `room_id`.

  ## Examples

      MyApp.Presence.list("general")
      #=> []
  """
  @spec list(String.t()) :: [OnlineUser.t()]
  def list(room_id) when is_binary(room_id) do
    Agent.get(__MODULE__, fn users_by_room ->
      users_by_room
      |> Map.get(room_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.name)
    end)
  end

  @spec put_user(room_users(), room_id(), OnlineUser.t()) :: room_users()
  defp put_user(users_by_room, room_id, %OnlineUser{id: user_id} = user) do
    room_users =
      users_by_room
      |> Map.get(room_id, %{})
      |> Map.put(user_id, user)

    Map.put(users_by_room, room_id, room_users)
  end

  @spec delete_user(room_users(), room_id(), user_id()) :: room_users()
  defp delete_user(users_by_room, room_id, user_id) do
    room_users =
      users_by_room
      |> Map.get(room_id, %{})
      |> Map.delete(user_id)

    if map_size(room_users) == 0 do
      Map.delete(users_by_room, room_id)
    else
      Map.put(users_by_room, room_id, room_users)
    end
  end

  @spec broadcast(room_id()) :: :ok
  defp broadcast(room_id) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "room:" <> room_id, {:presence_changed, list(room_id)})
  end
end
