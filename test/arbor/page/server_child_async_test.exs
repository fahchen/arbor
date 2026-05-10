defmodule Arbor.Page.ServerChildAsyncTest do
  @moduledoc """
  Verifies async + lifecycle-hook support on child stores: assign_async,
  start_async, cancel_async, stream_async, plus the `:handle_async` and
  `:before_command` hook chains dispatched along the path chain so hooks
  attached on the child socket fire alongside any root-attached defaults.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Arbor.AsyncResult
  alias Arbor.Page.PatchEnvelope
  alias Arbor.Page.Server
  alias Arbor.Page.StoreRegistry

  @async_terminal_events [
    [:arbor, :async, :stop],
    [:arbor, :async, :exception]
  ]

  defmodule WidgetStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :data, String.t() | nil
      field :slow, Arbor.AsyncResult.of(String.t())
      stream :messages, %{id: String.t(), body: String.t()}
    end

    attr :test_pid, pid(), required: true

    command :load do
      payload :id, String.t()
    end

    command :start_warm do
      payload :tag, String.t()
    end

    command :start_slow

    command :cancel_slow

    command :load_messages

    def mount(socket) do
      hook_pid = socket.assigns.test_pid

      socket =
        socket
        |> Arbor.Lifecycle.attach_hook(:trace_async, :handle_async, fn name, result, sock ->
          send(hook_pid, {:child_handle_async_hook, sock.id, name, result})
          {:cont, sock}
        end)
        |> Arbor.Lifecycle.attach_hook(:trace_before, :before_command, fn name, payload, sock ->
          send(hook_pid, {:child_before_command_hook, sock.id, name, payload})
          {:cont, sock}
        end)
        |> Arbor.Socket.assign(:data, nil)
        |> Arbor.Socket.assign(:slow, AsyncResult.loading())

      {:ok, socket}
    end

    def to_state(socket) do
      %{data: Map.get(socket.assigns, :data), slow: socket.assigns.slow, messages: []}
    end

    def handle_command(:load, %{"id" => id}, socket) do
      socket =
        Arbor.Async.assign_async(socket, :data, fn ->
          {:ok, "loaded:" <> id}
        end)

      {:reply, %{ok: true}, socket}
    end

    def handle_command(:start_warm, %{"tag" => tag}, socket) do
      {:noreply,
       Arbor.Async.start_async(socket, :warm, fn ->
         {:warmed, tag}
       end)}
    end

    def handle_command(:start_slow, _payload, socket) do
      {:noreply,
       Arbor.Async.assign_async(socket, :slow, fn ->
         Process.sleep(60_000)
         {:ok, "never"}
       end)}
    end

    def handle_command(:cancel_slow, _payload, socket) do
      {:noreply, Arbor.Async.cancel_async(socket, :slow, :user_navigated)}
    end

    def handle_command(:load_messages, _payload, socket) do
      {:noreply,
       Arbor.Async.stream_async(socket, :messages, fn ->
         {:ok, [%{id: "m1", body: "hi"}, %{id: "m2", body: "yo"}]}
       end)}
    end

    def handle_async(:warm, {:ok, {:warmed, _tag}}, socket) do
      send(socket.assigns.test_pid, {:child_handle_async_callback, socket.id, :warm})
      {:noreply, socket}
    end

    def handle_async(_name, _result, socket), do: {:noreply, socket}
  end

  defmodule RootStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :widget, map()
    end

    def mount(socket), do: {:ok, socket}

    def to_state(socket) do
      %{widget: Arbor.Child.child(WidgetStore, id: "w1", test_pid: socket.assigns.test_pid)}
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "child store async + hook routing" do
    test "scenario 1: assign_async from a child writes AsyncResult onto the child's assigns" do
      attach_async_terminal_handler!()

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, ["w1"], :load, %{"id" => "abc"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _, %{name: :data, status: :ok}}, 2_000

      assert %AsyncResult{status: :ok, result: "loaded:abc"} = child_assign(pid, :data)

      shutdown_server(pid)
    end

    test "scenario 2: start_async from a child invokes the child's handle_async/3" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, ["w1"], :start_warm, %{"tag" => "ada"})

      assert_receive {:child_handle_async_callback, "w1", :warm}, 1_000
      shutdown_server(pid)
    end

    test "scenario 3: :handle_async hook attached in the child's mount fires for child tasks" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, ["w1"], :start_warm, %{"tag" => "ada"})

      assert_receive {:child_handle_async_hook, "w1", :warm, {:ok, {:warmed, "ada"}}}, 1_000
      shutdown_server(pid)
    end

    test "scenario 4: :before_command hook attached in the child's mount fires when a command targets it" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, ["w1"], :load, %{"id" => "xyz"})

      assert_receive {:child_before_command_hook, "w1", :load, %{"id" => "xyz"}}, 1_000
      shutdown_server(pid)
    end

    test "scenario 5: cancel_async from a child resolves the slot to failed/{:exit, reason}" do
      attach_async_terminal_handler!()

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, ["w1"], :start_slow, %{})
      assert {:ok, _reply} = Server.command(pid, ["w1"], :cancel_slow, %{})

      assert_receive {:telemetry, [:arbor, :async, :stop], _, %{name: :slow, status: :failed}},
                     2_000

      assert %AsyncResult{status: :failed, reason: {:exit, :user_navigated}} =
               child_assign(pid, :slow)

      shutdown_server(pid)
    end

    test "scenario 6: stream_async from a child seeds stream ops + AsyncResult on the child" do
      attach_async_terminal_handler!()

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, ["w1"], :load_messages, %{})

      assert_receive {:telemetry, [:arbor, :async, :stop], _, %{name: :messages, status: :ok}},
                     2_000

      assert %AsyncResult{status: :ok, result: true} = child_assign(pid, :messages)
      shutdown_server(pid)
    end
  end

  defp start! do
    {:ok, pid} =
      Server.start_link(
        {RootStore, %{"page_id" => "p1", test_pid: self()}, %{transport_pid: self()}}
      )

    pid
  end

  defp flush_initial! do
    assert_receive {:patch, %PatchEnvelope{base_version: 0, version: 1}}, 1_000
  end

  defp attach_async_terminal_handler! do
    test_pid = self()
    handler_id = "child-async-terminal-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach_many(
      handler_id,
      @async_terminal_events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp child_assign(pid, key) do
    %{store_registry: registry} = :sys.get_state(pid)
    entry = StoreRegistry.get(registry, ["w1"])
    Map.get(entry.socket.assigns, key)
  end

  # Child-async scenarios leave the linked page server alive until test exit,
  # so shut it down explicitly inside `capture_log/1` to absorb terminate logs.
  defp shutdown_server(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      capture_log(fn ->
        GenServer.stop(pid, :shutdown)

        receive do
          {:DOWN, ^ref, _type, _object, _reason} -> :ok
        after
          1_000 -> :ok
        end

        Logger.flush()
      end)
    end
  end
end
