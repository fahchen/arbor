defmodule Arbor.StreamTest do
  use ExUnit.Case, async: true

  alias Arbor.Socket
  alias Arbor.Stream

  defmodule MessagesStore do
    @moduledoc false

    use Arbor.Store

    state do
      stream :messages, String.t(), limit: -3
      stream :songs, String.t()
    end

    def to_state(_socket), do: %{messages: [], songs: []}
  end

  setup do
    {:ok, socket: %Socket{module: MessagesStore, assigns: %{}, private: %{}}}
  end

  describe "Scenario: Default item_key depends on item id" do
    test "default item_key prefixes the stream name", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "abc"})
      assert [%{op: "insert", item_key: "songs-abc"}] = Stream.pending_ops(socket)
    end
  end

  describe "Scenario: Default item_key and missing item id" do
    test "missing :id raises ArgumentError pointing at the failing call site", %{socket: socket} do
      assert_raise ArgumentError, ~r/missing the `:id` field/, fn ->
        Stream.stream_insert(socket, :songs, %{body: "no id"})
      end
    end
  end

  describe "Rule: socket-pipe stream API mirrors Phoenix.LiveView" do
    test "stream/3 seeds items in order", %{socket: socket} do
      socket = Stream.stream(socket, :songs, [%{id: "1"}, %{id: "2"}])

      ops = Stream.pending_ops(socket)

      assert [
               %{op: "insert", item_key: "songs-1"},
               %{op: "insert", item_key: "songs-2"}
             ] = ops
    end

    test "stream_insert/3 with at: 0 records prepend position", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"}, at: 0)
      assert [%{op: "insert", at: 0}] = Stream.pending_ops(socket)
    end

    test "stream_delete_by_item_key/3 emits delete op", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "1"})
        |> Stream.stream_delete_by_item_key(:songs, "songs-1")

      assert [
               %{op: "insert", item_key: "songs-1"},
               %{op: "delete", item_key: "songs-1"}
             ] = Stream.pending_ops(socket)
    end

    test "stream_delete/3 derives item_key", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "x"})
        |> Stream.stream_delete(:songs, %{id: "x"})

      ops = Stream.pending_ops(socket)
      assert Enum.any?(ops, &match?(%{op: "delete", item_key: "songs-x"}, &1))
    end
  end

  describe "Scenario: Insert is upsert by item_key" do
    test "upserting an existing key re-emits insert without changing index", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "1"})
        |> Stream.stream_insert(:songs, %{id: "1", body: "edited"})

      assert [
               %{op: "insert", item_key: "songs-1"},
               %{op: "insert", item_key: "songs-1"}
             ] = Stream.pending_ops(socket)

      # Index length unchanged after upsert.
      assert %{songs: %{item_keys: ["songs-1"]}} = socket.assigns.__streams__
    end
  end

  describe "Scenario: update_only true on a missing item_key is a no-op" do
    test "no op queued for a missing key", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "9"}, update_only: true)
      assert [] = Stream.pending_ops(socket)
    end
  end

  describe "Rule: stream_configure must precede other stream ops for the same name" do
    test "configure after insert raises", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"})

      assert_raise ArgumentError, ~r/stream_configure\(:songs/, fn ->
        Stream.stream_configure(socket, :songs, limit: 10)
      end
    end

    test "configure before insert is fine", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_configure(:songs, limit: 10)
        |> Stream.stream_insert(:songs, %{id: "1"})

      assert [
               %{op: "configure", name: "songs"},
               %{op: "insert", name: "songs"}
             ] = Stream.pending_ops(socket)
    end
  end

  describe "Rule: pending ops flush once per handler invocation" do
    test "flush returns ops in queue order and clears the accumulator", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "1"})
        |> Stream.stream_insert(:songs, %{id: "2"})

      {ops, socket} = Stream.flush_pending_ops(socket)
      assert length(ops) == 2

      assert Stream.pending_ops(socket) == []

      # Flushing again is a no-op — ops do not survive across handlers.
      {ops_again, _socket} = Stream.flush_pending_ops(socket)
      assert ops_again == []
    end
  end

  describe "Rule: After flush only the item_key index is retained" do
    test "server retains ordered item_keys but drops item bodies", %{socket: socket} do
      seeded =
        Enum.reduce(1..1000, socket, fn i, acc ->
          Stream.stream_insert(acc, :songs, %{id: Integer.to_string(i)})
        end)

      {_ops, after_flush} = Stream.flush_pending_ops(seeded)

      %{songs: %{item_keys: keys}} = after_flush.assigns.__streams__
      assert length(keys) == 1000
      assert hd(keys) == "songs-1"
      assert List.last(keys) == "songs-1000"

      # No item body anywhere on the socket assigns/private.
      refute Enum.any?(keys, &is_map/1)
    end
  end

  describe "Rule: :limit re-evaluated only when the item_key index grows" do
    test "upsert at the limit emits insert only", %{socket: socket} do
      # `messages` has limit: -3.
      socket =
        Enum.reduce(["a", "b", "c"], socket, fn id, acc ->
          Stream.stream_insert(acc, :messages, %{id: id})
        end)

      {_ops, socket} = Stream.flush_pending_ops(socket)

      socket = Stream.stream_insert(socket, :messages, %{id: "a", body: "edited"})
      ops = Stream.pending_ops(socket)

      assert [%{op: "insert", item_key: "messages-a"}] = ops
      refute Enum.any?(ops, &match?(%{op: "delete"}, &1))
    end

    test "new insert at the limit emits insert + delete for trimmed key", %{socket: socket} do
      socket =
        Enum.reduce(["a", "b", "c"], socket, fn id, acc ->
          Stream.stream_insert(acc, :messages, %{id: id})
        end)

      {_ops, socket} = Stream.flush_pending_ops(socket)

      # Default at: -1 (append). With limit: -3 (keep last 3), the 4th insert
      # evicts the head (`messages-a`).
      socket = Stream.stream_insert(socket, :messages, %{id: "d"})
      ops = Stream.pending_ops(socket)

      assert Enum.any?(ops, &match?(%{op: "insert", item_key: "messages-d"}, &1))
      assert Enum.any?(ops, &match?(%{op: "delete", item_key: "messages-a"}, &1))

      %{messages: %{item_keys: keys}} = socket.assigns.__streams__
      assert keys == ["messages-b", "messages-c", "messages-d"]
    end
  end

  describe "Silent refresh: stream(reset: true)" do
    test "reset followed by per-item inserts in same envelope", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "old"})
      {_ops, socket} = Stream.flush_pending_ops(socket)

      socket = Stream.stream(socket, :songs, [%{id: "1"}, %{id: "2"}], reset: true)
      ops = Stream.pending_ops(socket)

      assert [
               %{op: "reset", name: "songs"},
               %{op: "insert", item_key: "songs-1"},
               %{op: "insert", item_key: "songs-2"}
             ] = ops

      %{songs: %{item_keys: ["songs-1", "songs-2"]}} = socket.assigns.__streams__
    end
  end
end
