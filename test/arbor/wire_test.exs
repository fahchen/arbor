defmodule Arbor.WireTest do
  use ExUnit.Case, async: true

  alias Arbor.Wire

  defmodule LeafState do
    @moduledoc false

    use Arbor.State

    state do
      field :title, String.t()
      field :status, :active | :paused
    end
  end

  defmodule StreamState do
    @moduledoc false

    use Arbor.State

    state do
      stream :messages, String.t()
    end
  end

  test "atoms convert to wire form" do
    assert Wire.to_wire(:active) == "active"
    assert Wire.to_wire(nil) == nil
    assert Wire.to_wire(true) == true
    assert Wire.to_wire(false) == false
  end

  test "scalars pass through" do
    assert Wire.to_wire("hello") == "hello"
    assert Wire.to_wire(42) == 42
    assert Wire.to_wire(3.14) == 3.14
  end

  test "lists recurse element-wise" do
    assert Wire.to_wire([:active, :paused, "ok"]) == ["active", "paused", "ok"]
  end

  test "maps stringify atom keys and recurse on values" do
    assert Wire.to_wire(%{title: "Inbox", status: :paused}) ==
             %{"title" => "Inbox", "status" => "paused"}
  end

  test "auto-derives for Arbor.State / Arbor.Store structs" do
    state = struct!(LeafState, title: "Inbox", status: :active)
    assert Wire.to_wire(state) == %{"title" => "Inbox", "status" => "active"}
  end

  test "auto-derived stream fields serialize as markers" do
    state = struct!(StreamState, messages: ["ignored"])

    assert Wire.to_wire(state) == %{
             "messages" => %{"__arbor_stream__" => "messages"}
           }
  end

  test "raises a clear error when an unresolved Arbor.Child slips through" do
    child = Arbor.Child.child(LeafState, id: "x", title: "y")

    assert_raise ArgumentError, ~r/unresolved child placeholder/, fn ->
      Wire.to_wire(child)
    end
  end
end
