defmodule Arbor.StreamAsyncTest do
  use ExUnit.Case, async: true

  alias Arbor.Async
  alias Arbor.AsyncResult
  alias Arbor.Socket
  alias Arbor.Stream

  defmodule MessagesStore do
    @moduledoc false
    use Arbor.Store

    state do
      stream :messages, %{id: String.t(), body: String.t()}
    end

    def mount(socket), do: {:ok, socket}
    def to_state(_socket), do: %{messages: []}
  end

  describe "stream_async/3 happy path" do
    test "initializes the stream slot before task completion" do
      socket = base_socket()
      socket = Async.stream_async(socket, :messages, fn -> {:ok, [%{id: "1", body: "hi"}]} end)

      assert %AsyncResult{status: :loading} = socket.assigns.messages
      assert %{messages: %Stream.Slot{}} = socket.assigns[Stream.assigns_key()]
      assert Stream.pending_ops(socket) == []
    end

    test "writes loading and seeds stream on success" do
      socket = base_socket()

      socket = Async.stream_async(socket, :messages, fn -> {:ok, [%{id: "1", body: "hi"}]} end)
      assert %AsyncResult{status: :loading} = socket.assigns.messages

      {classified, entry} = await_task(socket, :messages)
      socket = Async.apply_task_result(socket, :messages, entry, classified)

      assert %AsyncResult{status: :ok, result: true, reason: nil} = socket.assigns.messages

      pending = Stream.pending_ops(socket)
      assert Enum.any?(pending, fn op -> op.op == "insert" and op.item_key == "messages-1" end)
    end

    test "stream opts pass through to stream/4" do
      socket = base_socket()

      socket =
        Async.stream_async(socket, :messages, fn ->
          {:ok, [%{id: "1", body: "hi"}], at: 0, limit: -100}
        end)

      {classified, entry} = await_task(socket, :messages)
      socket = Async.apply_task_result(socket, :messages, entry, classified)

      assert [%{op: "insert", at: 0}] = Stream.pending_ops(socket)
    end
  end

  describe "stream_async/3 failure" do
    test "{:error, reason} writes failed and leaves stream untouched" do
      socket = base_socket()
      socket = Async.stream_async(socket, :messages, fn -> {:error, :rate_limited} end)
      {classified, entry} = await_task(socket, :messages)

      socket = Async.apply_task_result(socket, :messages, entry, classified)

      assert %AsyncResult{status: :failed, reason: {:error, :rate_limited}} =
               socket.assigns.messages

      assert Stream.pending_ops(socket) == []
    end

    test "invalid shape raises inside the task and surfaces as failed {:exit, ...}" do
      socket = base_socket()
      socket = Async.stream_async(socket, :messages, fn -> [%{id: "1"}] end)
      {classified, entry} = await_task(socket, :messages)

      socket = Async.apply_task_result(socket, :messages, entry, classified)

      assert %AsyncResult{status: :failed, reason: {:exit, _reason}} = socket.assigns.messages
    end
  end

  describe "stream_async/3 reset" do
    test ":reset re-emits loading without prior" do
      prior = AsyncResult.ok(nil, true)

      socket =
        base_socket()
        |> Socket.assign(:messages, prior)
        |> Async.stream_async(:messages, fn -> {:ok, []} end, reset: true)

      assert %AsyncResult{status: :loading, result: nil} = socket.assigns.messages
    end
  end

  defp base_socket do
    %Socket{module: MessagesStore, parent_path: [], id: ""}
  end

  defp await_task(socket, name) do
    {:ok, entry} = Async.fetch_tracking(socket, name)
    ref = entry.ref

    receive do
      {^ref, classified} -> {classified, entry}
    after
      1_000 -> flunk("no task result for #{inspect(name)}")
    end
  end
end
