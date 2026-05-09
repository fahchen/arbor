defmodule Arbor.Page.ServerAsyncTest do
  use ExUnit.Case, async: true

  alias Arbor.AsyncResult
  alias Arbor.Page.PatchEnvelope
  alias Arbor.Page.Server

  defmodule AsyncStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :profile, Arbor.AsyncResult.of(%{name: String.t()})
      field :cache_status, String.t()
    end

    command :load_profile do
      payload :name, String.t()
    end

    command :start_warm do
      payload :name, String.t()
    end

    command :raising_handle_async

    command :cancel_profile do
      payload :reason, String.t()
    end

    # Reference cancel atoms used by the test so `String.to_existing_atom/1`
    # in `handle_command/3` can resolve them at runtime.
    @cancel_reasons [:user_left]
    def __cancel_reasons__, do: @cancel_reasons

    def mount(socket) do
      socket =
        socket
        |> Arbor.Socket.assign(:profile, AsyncResult.loading())
        |> Arbor.Socket.assign(:cache_status, "cold")

      {:ok, socket}
    end

    def to_state(socket) do
      %{profile: socket.assigns.profile, cache_status: socket.assigns.cache_status}
    end

    def handle_command(:load_profile, %{"name" => name}, socket) do
      socket = Arbor.Async.assign_async(socket, :profile, fn -> {:ok, %{name: name}} end)
      {:noreply, socket}
    end

    def handle_command(:start_warm, %{"name" => name}, socket) do
      socket = Arbor.Async.start_async(socket, :warm_cache, fn -> {:warmed, name} end)
      {:noreply, socket}
    end

    def handle_command(:raising_handle_async, _payload, socket) do
      socket = Arbor.Async.start_async(socket, :raises, fn -> :ok end)
      {:noreply, socket}
    end

    def handle_command(:cancel_profile, %{"reason" => reason}, socket) do
      socket =
        Arbor.Async.assign_async(socket, :profile, fn ->
          Process.sleep(60_000)
          {:ok, %{name: "never"}}
        end)

      socket = Arbor.Async.cancel_async(socket, :profile, String.to_existing_atom(reason))
      {:noreply, socket}
    end

    def handle_async(:warm_cache, {:ok, {:warmed, name}}, socket) do
      {:noreply, Arbor.Socket.assign(socket, :cache_status, "warm:" <> name)}
    end

    def handle_async(:raises, {:ok, _value}, _socket) do
      raise "boom-in-handle-async"
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "assign_async via command handler" do
    test "writes loading then ok and emits patch envelopes" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_profile, %{"name" => "ada"})

      # The synchronous loading write transitions :profile from
      # `AsyncResult.loading()` (set at mount) to `AsyncResult.loading(prior)`
      # — same wire shape, so the diff is empty and no envelope is emitted
      # (BDR-0018). The task completion transitions to `:ok` and produces a
      # single envelope with the replace ops.
      ops = collect_envelope_ops!()

      assert Enum.any?(ops, fn op ->
               op.op == "replace" and op.path == "/profile/status" and op.value == "ok"
             end)

      assert Enum.any?(ops, fn op ->
               op.op == "replace" and op.path == "/profile/result" and
                 op.value == %{"name" => "ada"}
             end)
    end
  end

  describe "start_async via command handler" do
    test "delivers result to handle_async/3 and triggers a patch" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :start_warm, %{"name" => "ada"})

      # start_async does not mutate assigns directly. The patch arrives after
      # `handle_async/3` runs and updates :cache_status.
      ops = collect_envelope_ops!()

      assert Enum.any?(ops, fn op ->
               op.op == "replace" and op.path == "/cache_status" and op.value == "warm:ada"
             end)
    end
  end

  describe "handle_async/3 exception is caught (BDR-0020)" do
    test "runtime survives, emits :exception telemetry, processes subsequent commands" do
      attach_telemetry_handler!([:arbor, :async, :exception])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :raising_handle_async, %{})

      assert_receive {:telemetry, [:arbor, :async, :exception], _measurements, metadata}, 1_000
      assert metadata.name == :raises
      assert metadata.kind == :start

      # Page server still alive
      assert Process.alive?(pid)

      # Subsequent commands still work
      assert {:ok, _reply} = Server.command(pid, [], :load_profile, %{"name" => "after_crash"})
    end
  end

  describe "cancel_async by name during a handler" do
    test "kills task; :DOWN routes a failed write through handle_info" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :cancel_profile, %{"reason" => "user_left"})

      # Loading write is a no-op transition (loading -> loading). cancel_async
      # by name does not pre-write; the failed write arrives via the :DOWN
      # message, producing one envelope.
      ops = collect_envelope_ops!(2_000)

      assert Enum.any?(ops, fn op ->
               op.op == "replace" and op.path == "/profile/status" and op.value == "failed"
             end)
    end
  end

  defp start! do
    {:ok, pid} = Server.start_link({AsyncStore, %{"page_id" => "p1"}, %{transport_pid: self()}})
    pid
  end

  defp flush_initial! do
    assert_receive {:patch, %PatchEnvelope{base_version: 0, version: 1}}
  end

  # Drain envelopes until one with non-empty `ops` arrives, returning its
  # ops list. Useful when a handler emits one or more no-op envelopes
  # (loading -> loading) before the meaningful transition.
  defp collect_envelope_ops!(timeout \\ 1_000) do
    receive do
      {:patch, %PatchEnvelope{ops: []}} -> collect_envelope_ops!(timeout)
      {:patch, %PatchEnvelope{ops: ops}} -> ops
    after
      timeout -> flunk("no envelope with ops within #{timeout}ms")
    end
  end

  defp attach_telemetry_handler!(event) do
    test_pid = self()
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
