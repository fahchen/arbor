defmodule Musubi.WireTest do
  use ExUnit.Case, async: true

  alias Musubi.Wire

  defmodule LeafState do
    @moduledoc false

    use Musubi.State

    state do
      field :title, String.t()
      field :status, :active | :paused
    end
  end

  defmodule StreamState do
    @moduledoc false

    use Musubi.State

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

  test "Calendar types serialize to ISO8601 strings" do
    assert Wire.to_wire(~U[2026-05-26 09:14:06Z]) == "2026-05-26T09:14:06Z"
    assert Wire.to_wire(~N[2026-05-26 09:14:06]) == "2026-05-26T09:14:06"
    assert Wire.to_wire(~D[2026-05-26]) == "2026-05-26"
    assert Wire.to_wire(~T[09:14:06]) == "09:14:06"
  end

  test "URI serializes to its string form" do
    assert Wire.to_wire(URI.parse("https://example.com/path?q=1")) ==
             "https://example.com/path?q=1"
  end

  test "Calendar types and URI recurse inside maps and lists" do
    assert Wire.to_wire(%{at: ~D[2026-05-26], links: [URI.parse("https://x.test")]}) ==
             %{"at" => "2026-05-26", "links" => ["https://x.test"]}
  end

  test "auto-derives for Musubi.State / Musubi.Store structs" do
    state = struct!(LeafState, title: "Inbox", status: :active)
    assert Wire.to_wire(state) == %{"title" => "Inbox", "status" => "active"}
  end

  test "auto-derived stream fields serialize as markers" do
    state = struct!(StreamState, messages: ["ignored"])

    assert Wire.to_wire(state) == %{
             "messages" => %{"__musubi_stream__" => "messages"}
           }
  end

  test "raises a clear error when an unresolved Musubi.Child slips through" do
    child = Musubi.Child.child(LeafState, id: "x", title: "y")

    assert_raise ArgumentError, ~r/unresolved child placeholder/, fn ->
      Wire.to_wire(child)
    end
  end
end
