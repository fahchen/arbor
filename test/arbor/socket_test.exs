defmodule Arbor.SocketTest do
  use ExUnit.Case, async: true

  alias Arbor.Socket

  describe "struct defaults" do
    test "matches the frozen socket shape" do
      socket = %Socket{}

      assert socket.assigns == %{}
      assert socket.id == nil
      assert socket.parent_path == []
      assert socket.module == nil
      assert socket.endpoint == nil
      assert socket.topic == nil
      assert socket.transport_pid == nil
      assert socket.private == %{}
    end
  end

  describe "assign helpers" do
    test "assign/3 records changes only when the value differs by ===" do
      socket = Socket.assign(%Socket{}, :status, :ready)

      assert socket.assigns.status == :ready
      assert socket.assigns.__changed__ == %{status: true}
      assert Socket.changed?(socket, :status)

      unchanged = Socket.assign(socket, :status, :ready)

      assert unchanged == socket
      assert unchanged.assigns.__changed__ == %{status: true}
    end

    test "assign/2 handles maps and keyword lists" do
      socket =
        %Socket{}
        |> Socket.assign(%{title: "Inbox"})
        |> Socket.assign(unread_count: 3)

      assert socket.assigns.title == "Inbox"
      assert socket.assigns.unread_count == 3
      assert socket.assigns.__changed__ == %{title: true, unread_count: true}
    end

    test "update_assign/3 is chainable" do
      socket =
        %Socket{}
        |> Socket.assign(:count, 1)
        |> Socket.update_assign(:count, &(&1 + 1))
        |> Socket.update_assign(:count, &(&1 + 1))

      assert socket.assigns.count == 3
      assert socket.assigns.__changed__ == %{count: true}
    end

    test "reset_changed/1 clears tracked changes" do
      socket =
        %Socket{}
        |> Socket.assign(:title, "old")
        |> Socket.reset_changed()

      assert socket.assigns.__changed__ == %{}
      refute Socket.changed?(socket, :title)
    end

    test "consumed_keys_changed?/2 only matches consumed keys" do
      socket =
        %Socket{}
        |> Socket.assign(:sibling_field, 1)
        |> Socket.assign(:title, "Inbox")
        |> Socket.reset_changed()
        |> Socket.assign(:sibling_field, 2)

      refute Socket.consumed_keys_changed?(socket, [:title, :unread_count])
      assert Socket.consumed_keys_changed?(socket, [:title, :sibling_field])
    end
  end

  describe "invoke/3" do
    test "calls a function attr and returns the same socket" do
      parent = self()

      socket =
        Socket.assign(%Socket{}, :on_select, fn payload -> send(parent, {:selected, payload}) end)

      assert Socket.invoke(socket, :on_select, %{id: "prod_1"}) == socket
      assert_received {:selected, %{id: "prod_1"}}
    end

    test "raises clearly when the callback is missing" do
      assert_raise ArgumentError, ~r/missing callback assign :missing/, fn ->
        Socket.invoke(%Socket{}, :missing, %{id: "prod_1"})
      end
    end
  end
end
