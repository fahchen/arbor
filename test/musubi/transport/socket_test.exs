defmodule Musubi.Transport.SocketTest do
  use ExUnit.Case, async: true

  alias Musubi.Transport.Socket, as: TransportSocket

  describe "build_connect_socket/2" do
    test "normalizes a present session map" do
      socket = TransportSocket.build_connect_socket(%{}, %{session: %{"user_id" => "u1"}})

      assert Musubi.Socket.session(socket) == %{"user_id" => "u1"}
    end

    test "defaults to %{} when :session key is missing" do
      socket = TransportSocket.build_connect_socket(%{}, %{})

      assert Musubi.Socket.session(socket) == %{}
    end

    test "tolerates connect_info = %{session: nil} from cookieless first visit" do
      # Phoenix's Plug.Session.Cookie produces `%{session: nil}` on a
      # WebSocket upgrade with no cookie. The key is present, so the
      # Map.get/3 default does not fire — must be normalized in-call.
      socket = TransportSocket.build_connect_socket(%{}, %{session: nil})

      assert Musubi.Socket.session(socket) == %{}
    end

    test "normalizes a non-map session value to %{}" do
      # `put_session/2` only accepts maps; any out-of-contract value (list,
      # binary, atom, …) routed through here must be normalized rather
      # than crashing the WebSocket handshake.
      for bad <- [[], "not-a-map", :not_a_map, 42] do
        socket = TransportSocket.build_connect_socket(%{}, %{session: bad})
        assert Musubi.Socket.session(socket) == %{}
      end
    end
  end
end
