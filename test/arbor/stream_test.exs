defmodule Arbor.StreamTest do
  use ExUnit.Case, async: true

  alias Arbor.Socket
  alias Arbor.Stream
  alias Arbor.Stream.Slot

  defmodule MessagesStore do
    @moduledoc false

    use Arbor.Store

    state do
      stream :messages, String.t(), limit: -3
      stream :songs, String.t()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{messages: stream(:messages), songs: stream(:songs)}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
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

  describe "Rule: socket-pipe stream API" do
    test "stream/3 seeds items in order, each as an insert op", %{socket: socket} do
      socket = Stream.stream(socket, :songs, [%{id: "1"}, %{id: "2"}])

      ops = Stream.pending_ops(socket)

      assert [
               %{op: "insert", stream: "songs", item_key: "songs-1"},
               %{op: "insert", stream: "songs", item_key: "songs-2"}
             ] = ops
    end

    test "stream_insert/3 with at: 0 records prepend position", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"}, at: 0)
      assert [%{op: "insert", at: 0}] = Stream.pending_ops(socket)
    end

    test "stream_insert/3 records :limit per-op (no server-side trim)", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"}, limit: -3)
      assert [%{op: "insert", limit: -3}] = Stream.pending_ops(socket)
    end

    test "stream_insert/3 with no :limit emits limit: nil", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"})
      assert [%{op: "insert", limit: nil}] = Stream.pending_ops(socket)
    end

    test "stream_insert queues without checking existence (no server-side upsert)", %{
      socket: socket
    } do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "1"})
        |> Stream.stream_insert(:songs, %{id: "1", body: "edited"})

      assert [
               %{op: "insert", item_key: "songs-1"},
               %{op: "insert", item_key: "songs-1"}
             ] = Stream.pending_ops(socket)
    end

    test "stream_delete_by_item_key/3 emits delete op without existence check", %{socket: socket} do
      # Note: no preceding insert is required.
      socket = Stream.stream_delete_by_item_key(socket, :songs, "songs-1")
      assert [%{op: "delete", item_key: "songs-1"}] = Stream.pending_ops(socket)
    end

    test "stream_delete/3 derives item_key", %{socket: socket} do
      socket = Stream.stream_delete(socket, :songs, %{id: "x"})

      ops = Stream.pending_ops(socket)
      assert [%{op: "delete", item_key: "songs-x"}] = ops
    end
  end

  describe "Rule: stream_configure must precede stream initialization" do
    test "configure after init raises (lifetime check)", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"})

      assert_raise ArgumentError, ~r/stream_configure\(:songs/, fn ->
        Stream.stream_configure(socket, :songs, limit: 10)
      end
    end

    test "configure before init applies overrides; first insert uses them", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_configure(:songs, item_key: fn item -> "custom-" <> item.id end)
        |> Stream.stream_insert(:songs, %{id: "1"})

      assert [%{op: "insert", item_key: "custom-1"}] = Stream.pending_ops(socket)
    end
  end

  describe "Rule: pending ops drain through the prune hook + flush" do
    test "flush_pending_ops returns ops in queue order and clears", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "1"})
        |> Stream.stream_insert(:songs, %{id: "2"})

      {ops, socket} = Stream.flush_pending_ops(socket)

      assert [
               %{op: "insert", item_key: "songs-1"},
               %{op: "insert", item_key: "songs-2"}
             ] = ops

      assert Stream.pending_ops(socket) == []
      {ops_again, _socket} = Stream.flush_pending_ops(socket)
      assert ops_again == []
    end

    test "drain_and_prune empties the LiveStream pending fields", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"})

      assert %Slot{inserts: [_one]} = socket.assigns.__streams__[:songs]

      socket = Stream.drain_and_prune(socket)

      assert %Slot{inserts: [], deletes: [], reset?: false} =
               socket.assigns.__streams__[:songs]
    end

    test "drain_and_prune clears __changed__", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"})

      assert MapSet.member?(Stream.changed_streams(socket), :songs)

      socket = Stream.drain_and_prune(socket)
      assert Stream.changed_streams(socket) == MapSet.new()
    end
  end

  describe "Rule: server forgets stream contents after flush" do
    test "after flush, no item bodies retained server-side", %{socket: socket} do
      seeded =
        Enum.reduce(1..1000, socket, fn i, acc ->
          Stream.stream_insert(acc, :songs, %{id: Integer.to_string(i)})
        end)

      {ops, after_flush} = Stream.flush_pending_ops(seeded)

      assert length(ops) == 1000

      assert %Slot{inserts: [], deletes: [], reset?: false} =
               after_flush.assigns.__streams__[:songs]
    end
  end

  describe "Silent refresh: stream(reset: true)" do
    test "queues reset op ahead of inserts", %{socket: socket} do
      socket = Stream.stream(socket, :songs, [%{id: "1"}, %{id: "2"}], reset: true)

      ops = Stream.pending_ops(socket)

      assert [
               %{op: "reset", stream: "songs"},
               %{op: "insert", item_key: "songs-1"},
               %{op: "insert", item_key: "songs-2"}
             ] = ops
    end
  end

  describe "Rule: __streams__ shape" do
    test "__ref__ counter increments per initialized stream", %{socket: socket} do
      socket =
        socket
        |> Stream.stream_insert(:songs, %{id: "1"})
        |> Stream.stream_insert(:messages, %{id: "1"})

      index = socket.assigns.__streams__
      assert index.__ref__ == 2
      assert %Slot{ref: 0} = index[:songs]
      assert %Slot{ref: 1} = index[:messages]
    end

    test "wire ops carry the stream's ref", %{socket: socket} do
      socket = Stream.stream_insert(socket, :songs, %{id: "1"})
      assert [%{op: "insert", ref: "0"}] = Stream.pending_ops(socket)
    end
  end
end
