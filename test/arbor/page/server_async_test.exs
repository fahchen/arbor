defmodule Arbor.Page.ServerAsyncTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Arbor.Async
  alias Arbor.AsyncResult
  alias Arbor.Page.PatchEnvelope
  alias Arbor.Page.Server
  alias Arbor.Page.StoreRegistry
  alias Arbor.Stream

  defmodule AsyncStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :profile, Arbor.AsyncResult.of(%{name: String.t()})
      field :user, Arbor.AsyncResult.of(String.t())
      field :org, Arbor.AsyncResult.of(String.t())
      field :cache_status, String.t()
      stream :messages, %{id: String.t(), body: String.t()}
    end

    command :load_profile do
      payload :name, String.t()
    end

    command :load_profile_blocked do
      payload :name, String.t()
      payload :tag, String.t()
    end

    command :load_profile_bad_return

    command :load_profile_raise

    command :load_profile_exit

    command :load_identity

    command :load_identity_missing_key

    command :start_warm do
      payload :name, String.t()
    end

    command :start_warm_blocked do
      payload :name, String.t()
      payload :tag, String.t()
    end

    command :start_warm_raise

    command :start_warm_exit

    command :cancel_warm do
      payload :reason, String.t()
    end

    command :raising_handle_async

    command :cancel_profile_by_name do
      payload :reason, String.t()
    end

    command :cancel_profile_by_value do
      payload :reason, String.t()
    end

    command :stream_messages do
      payload :mode, String.t()
    end

    command :stream_messages_blocked do
      payload :tag, String.t()
    end

    command :cancel_messages do
      payload :reason, String.t()
    end

    # Reference cancel atoms used by the test so `String.to_existing_atom/1`
    # in `handle_command/3` can resolve them at runtime.
    @cancel_reasons [:user_left, :user_navigated]
    def __cancel_reasons__, do: @cancel_reasons

    def mount(socket) do
      socket =
        socket
        |> Arbor.Socket.assign(:profile, AsyncResult.ok(nil, %{name: "cached"}))
        |> Arbor.Socket.assign(:user, AsyncResult.ok(nil, "cached-user"))
        |> Arbor.Socket.assign(:org, AsyncResult.ok(nil, "cached-org"))
        |> Arbor.Socket.assign(:cache_status, "cold")

      {:ok, socket}
    end

    def to_state(socket) do
      %{
        profile: socket.assigns.profile,
        user: socket.assigns.user,
        org: socket.assigns.org,
        cache_status: socket.assigns.cache_status,
        messages: []
      }
    end

    def handle_command(:load_profile, %{"name" => name}, socket) do
      socket = Arbor.Async.assign_async(socket, :profile, fn -> {:ok, %{name: name}} end)
      {:noreply, socket}
    end

    def handle_command(:load_profile_blocked, %{"name" => name, "tag" => tag}, socket) do
      test_pid = socket.assigns["test_pid"]

      socket =
        Arbor.Async.assign_async(socket, :profile, fn ->
          block_then_return(test_pid, {:profile, tag}, {:ok, %{name: name}})
        end)

      {:noreply, socket}
    end

    def handle_command(:load_profile_bad_return, _payload, socket) do
      {:noreply, Arbor.Async.assign_async(socket, :profile, fn -> 123 end)}
    end

    def handle_command(:load_profile_raise, _payload, socket) do
      {:noreply, Arbor.Async.assign_async(socket, :profile, fn -> raise "boom" end)}
    end

    def handle_command(:load_profile_exit, _payload, socket) do
      {:noreply, Arbor.Async.assign_async(socket, :profile, fn -> exit(:boom) end)}
    end

    def handle_command(:load_identity, _payload, socket) do
      socket =
        Arbor.Async.assign_async(socket, [:user, :org], fn ->
          {:ok, %{user: "ada", org: "arbor"}}
        end)

      {:noreply, socket}
    end

    def handle_command(:load_identity_missing_key, _payload, socket) do
      socket =
        Arbor.Async.assign_async(socket, [:user, :org], fn ->
          {:ok, %{user: "ada"}}
        end)

      {:noreply, socket}
    end

    def handle_command(:start_warm, %{"name" => name}, socket) do
      socket = Arbor.Async.start_async(socket, :warm_cache, fn -> {:warmed, name} end)
      {:noreply, socket}
    end

    def handle_command(:start_warm_blocked, %{"name" => name, "tag" => tag}, socket) do
      test_pid = socket.assigns["test_pid"]

      socket =
        Arbor.Async.start_async(socket, :warm_cache, fn ->
          block_then_return(test_pid, {:warm_cache, tag}, {:warmed, name})
        end)

      {:noreply, socket}
    end

    def handle_command(:start_warm_raise, _payload, socket) do
      {:noreply, Arbor.Async.start_async(socket, :warm_cache, fn -> raise "boom" end)}
    end

    def handle_command(:start_warm_exit, _payload, socket) do
      {:noreply, Arbor.Async.start_async(socket, :warm_cache, fn -> exit(:boom) end)}
    end

    def handle_command(:cancel_warm, %{"reason" => reason}, socket) do
      {:noreply, Arbor.Async.cancel_async(socket, :warm_cache, String.to_existing_atom(reason))}
    end

    def handle_command(:raising_handle_async, _payload, socket) do
      socket = Arbor.Async.start_async(socket, :raises, fn -> :ok end)
      {:noreply, socket}
    end

    def handle_command(:cancel_profile_by_name, %{"reason" => reason}, socket) do
      socket = Arbor.Async.cancel_async(socket, :profile, String.to_existing_atom(reason))
      {:noreply, socket}
    end

    def handle_command(:cancel_profile_by_value, %{"reason" => reason}, socket) do
      socket =
        Arbor.Async.cancel_async(socket, socket.assigns.profile, String.to_existing_atom(reason))

      {:noreply, socket}
    end

    def handle_command(:stream_messages, %{"mode" => "ok"}, socket) do
      {:noreply,
       Arbor.Async.stream_async(socket, :messages, fn ->
         {:ok, [%{id: "m1", body: "First"}, %{id: "m2", body: "Second"}]}
       end)}
    end

    def handle_command(:stream_messages, %{"mode" => "ok_with_opts"}, socket) do
      {:noreply,
       Arbor.Async.stream_async(socket, :messages, fn ->
         {:ok, [%{id: "m1", body: "First"}, %{id: "m2", body: "Second"}], at: 0, limit: -100}
       end)}
    end

    def handle_command(:stream_messages, %{"mode" => "ok_with_reset"}, socket) do
      {:noreply,
       Arbor.Async.stream_async(socket, :messages, fn ->
         {:ok, [%{id: "m3", body: "Reset First"}, %{id: "m4", body: "Reset Second"}], reset: true}
       end)}
    end

    def handle_command(:stream_messages, %{"mode" => "error"}, socket) do
      {:noreply, Arbor.Async.stream_async(socket, :messages, fn -> {:error, :rate_limited} end)}
    end

    def handle_command(:stream_messages, %{"mode" => "bad_return"}, socket) do
      {:noreply, Arbor.Async.stream_async(socket, :messages, fn -> 123 end)}
    end

    def handle_command(:stream_messages, %{"mode" => "not_enumerable"}, socket) do
      {:noreply, Arbor.Async.stream_async(socket, :messages, fn -> {:ok, 123} end)}
    end

    def handle_command(:stream_messages, %{"mode" => "raise"}, socket) do
      {:noreply, Arbor.Async.stream_async(socket, :messages, fn -> raise "boom" end)}
    end

    def handle_command(:stream_messages, %{"mode" => "exit"}, socket) do
      {:noreply, Arbor.Async.stream_async(socket, :messages, fn -> exit(:boom) end)}
    end

    def handle_command(:stream_messages_blocked, %{"tag" => tag}, socket) do
      test_pid = socket.assigns["test_pid"]

      socket =
        Arbor.Async.stream_async(socket, :messages, fn ->
          block_then_return(test_pid, {:messages, tag}, {:ok, [%{id: "m5", body: "Blocked"}]})
        end)

      {:noreply, socket}
    end

    def handle_command(:cancel_messages, %{"reason" => reason}, socket) do
      socket = Arbor.Async.cancel_async(socket, :messages, String.to_existing_atom(reason))
      {:noreply, socket}
    end

    def handle_async(:warm_cache, {:ok, {:warmed, name}}, socket) do
      {:noreply, Arbor.Socket.assign(socket, :cache_status, "warm:" <> name)}
    end

    def handle_async(:warm_cache, {:exit, reason}, socket) do
      {:noreply, Arbor.Socket.assign(socket, :cache_status, "exit:" <> inspect(reason))}
    end

    def handle_async(:raises, {:ok, _value}, _socket) do
      raise "boom-in-handle-async"
    end

    defp block_then_return(test_pid, key, result) do
      send(test_pid, {:task_ready, key, self()})

      receive do
        {:continue_task, ^key} -> result
      end
    end
  end

  defmodule MissingStreamStore do
    @moduledoc false
    use Arbor.Store

    command :load_messages

    def mount(socket), do: {:ok, socket}

    def to_state(_socket), do: %{}

    def handle_command(:load_messages, _payload, socket) do
      {:noreply, Arbor.Async.stream_async(socket, :messages, fn -> {:ok, []} end)}
    end
  end

  describe "assign_async/3,4" do
    test "writes the final ok value onto the socket" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_profile, %{"name" => "ada"})

      assert %AsyncResult{status: :ok, result: %{name: "ada"}, reason: nil} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :ok, result: %{name: "ada"}}, &1.assigns.profile)
               ).assigns.profile

    end

    test "exposes the loading state while a task is still running" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :load_profile_blocked, %{
                 "name" => "ada",
                 "tag" => "loading"
               })

      assert_receive {:patch, %PatchEnvelope{}}, 1_000

      assert %AsyncResult{status: :loading, result: %{name: "cached"}, reason: nil} =
               root_socket(pid).assigns.profile

      continue_task!(:profile, "loading")

      assert %AsyncResult{status: :ok, result: %{name: "ada"}, reason: nil} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :ok, result: %{name: "ada"}}, &1.assigns.profile)
               ).assigns.profile

    end

    test "writes all keys for multi-key tasks" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_identity, %{})

      socket =
        await_root_socket!(pid, fn socket ->
          match?(%AsyncResult{status: :ok, result: "ada"}, socket.assigns.user) and
            match?(%AsyncResult{status: :ok, result: "arbor"}, socket.assigns.org)
        end)

      assert %AsyncResult{status: :ok, result: "ada"} = socket.assigns.user
      assert %AsyncResult{status: :ok, result: "arbor"} = socket.assigns.org

    end

    test "marks invalid return values as failed" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_profile_bad_return, %{})

      socket = await_root_socket!(pid, &match?(%AsyncResult{status: :failed}, &1.assigns.profile))

      assert %AsyncResult{status: :failed, reason: {:exit, {:error, %ArgumentError{}, _stack}}} =
               socket.assigns.profile

    end

    test "marks missing multi-key results as failed" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_identity_missing_key, %{})

      socket =
        await_root_socket!(pid, fn socket ->
          match?(%AsyncResult{status: :failed}, socket.assigns.user) and
            match?(%AsyncResult{status: :failed}, socket.assigns.org)
        end)

      assert %AsyncResult{status: :failed, reason: {:exit, {:error, %ArgumentError{}, _stack}}} =
               socket.assigns.user

      assert %AsyncResult{status: :failed, reason: {:exit, {:error, %ArgumentError{}, _stack}}} =
               socket.assigns.org

    end

    test "marks raised exceptions as failed exits" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_profile_raise, %{})

      socket = await_root_socket!(pid, &match?(%AsyncResult{status: :failed}, &1.assigns.profile))

      assert %AsyncResult{
               status: :failed,
               reason: {:exit, {:error, %RuntimeError{message: "boom"}, _stack}}
             } = socket.assigns.profile

    end

    test "marks exited tasks as failed exits" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :load_profile_exit, %{})

      socket = await_root_socket!(pid, &match?(%AsyncResult{status: :failed}, &1.assigns.profile))

      assert %AsyncResult{status: :failed, reason: {:exit, :boom}} = socket.assigns.profile

    end

    test "cancel_async by name resolves the tracked assign to failed" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :load_profile_blocked, %{
                 "name" => "ada",
                 "tag" => "cancel-name"
               })

      assert %AsyncResult{status: :loading} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :loading}, &1.assigns.profile)
               ).assigns.profile

      assert {:ok, _reply} =
               Server.command(pid, [], :cancel_profile_by_name, %{"reason" => "user_left"})

      socket =
        await_root_socket!(
          pid,
          &match?(%AsyncResult{status: :failed, reason: {:exit, :user_left}}, &1.assigns.profile)
        )

      assert %AsyncResult{status: :failed, reason: {:exit, :user_left}} = socket.assigns.profile
      assert %{} = Async.tracking(socket)

    end

    test "cancel_async by AsyncResult pre-writes the failure and drops tracking" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :load_profile_blocked, %{
                 "name" => "ada",
                 "tag" => "cancel-value"
               })

      assert %AsyncResult{status: :loading} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :loading}, &1.assigns.profile)
               ).assigns.profile

      assert {:ok, _reply} =
               Server.command(pid, [], :cancel_profile_by_value, %{"reason" => "user_left"})

      socket =
        await_root_socket!(
          pid,
          &match?(%AsyncResult{status: :failed, reason: {:exit, :user_left}}, &1.assigns.profile)
        )

      assert %AsyncResult{status: :failed, reason: {:exit, :user_left}} = socket.assigns.profile
      assert %{} = Async.tracking(socket)

    end
  end

  describe "start_async/3,4" do
    test "does not mutate assigns before handle_async runs" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :start_warm_blocked, %{"name" => "ada", "tag" => "warm"})

      refute_receive {:patch, _envelope}, 100
      assert %{assigns: %{cache_status: "cold"}} = root_socket(pid)

      continue_task!(:warm_cache, "warm")

      assert %{assigns: %{cache_status: "warm:ada"}} =
               await_root_socket!(pid, &match?("warm:ada", &1.assigns.cache_status))

    end

    test "delivers raised task failures to handle_async/3" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :start_warm_raise, %{})

      socket = await_root_socket!(pid, &String.starts_with?(&1.assigns.cache_status, "exit:"))
      assert "exit:" <> reason = socket.assigns.cache_status
      assert reason =~ "RuntimeError"
      assert reason =~ "boom"

    end

    test "delivers task exits to handle_async/3" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :start_warm_exit, %{})

      assert %{assigns: %{cache_status: "exit::boom"}} =
               await_root_socket!(pid, &match?("exit::boom", &1.assigns.cache_status))

    end

    test "delivers cancel exits to handle_async/3" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :start_warm_blocked, %{"name" => "ada", "tag" => "cancel"})

      assert {:ok, _reply} =
               Server.command(pid, [], :cancel_warm, %{"reason" => "user_navigated"})

      assert %{assigns: %{cache_status: "exit::user_navigated"}} =
               await_root_socket!(pid, &match?("exit::user_navigated", &1.assigns.cache_status))

    end

    test "same-name overwrite keeps the latest result and lazy-discards the stale task" do
      attach_telemetry_handler!([:arbor, :async, :lazy_discard])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :start_warm_blocked, %{"name" => "first", "tag" => "first"})

      assert {:ok, _reply} = Server.command(pid, [], :start_warm, %{"name" => "second"})

      assert %{assigns: %{cache_status: "warm:second"}} =
               await_root_socket!(pid, &match?("warm:second", &1.assigns.cache_status))

      continue_task!(:warm_cache, "first")

      assert_receive {:telemetry, [:arbor, :async, :lazy_discard], _measurements, metadata}, 1_000
      assert %{name: :warm_cache, kind: :start} = metadata
      assert %{assigns: %{cache_status: "warm:second"}} = root_socket(pid)

    end
  end

  describe "handle_async/3" do
    test "runtime survives, emits :exception telemetry, processes subsequent commands" do
      attach_telemetry_handler!([:arbor, :async, :exception])

      pid = start!()
      flush_initial!()

      capture_log(fn ->
        assert {:ok, _reply} = Server.command(pid, [], :raising_handle_async, %{})

        assert_receive {:telemetry, [:arbor, :async, :exception], _measurements, metadata}, 1_000
        assert metadata.name == :raises
        assert metadata.kind == :start
        assert is_list(metadata.stacktrace)

        # Page server still alive
        assert Process.alive?(pid)
        assert %{assigns: %{cache_status: "cold"}} = root_socket(pid)

        # Subsequent commands still work
        assert {:ok, _reply} = Server.command(pid, [], :start_warm, %{"name" => "after_crash"})

        assert %{assigns: %{cache_status: "warm:after_crash"}} =
                 await_root_socket!(pid, &match?("warm:after_crash", &1.assigns.cache_status))

        Logger.flush()
      end)

    end
  end

  describe "stream_async/3,4" do
    test "raises before spawning when no stream slot is declared" do
      pid = start!(MissingStreamStore)
      flush_initial!()

      capture_log(fn ->
        assert catch_exit(Server.command(pid, [], :load_messages, %{}))
        Logger.flush()
      end)

      refute Process.alive?(pid)
    end

    test "writes the final ok status onto the socket" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :stream_messages, %{"mode" => "ok"})

      assert %AsyncResult{status: :ok, result: true, reason: nil} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :ok, result: true}, Map.get(&1.assigns, :messages))
               ).assigns.messages

    end

    test "shows loading while the stream task is running" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :stream_messages_blocked, %{"tag" => "loading"})

      assert %AsyncResult{status: :loading, result: nil, reason: nil} =
               root_socket(pid).assigns.messages

      continue_task!(:messages, "loading")

      assert %AsyncResult{status: :ok, result: true, reason: nil} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :ok, result: true}, Map.get(&1.assigns, :messages))
               ).assigns.messages

    end

    test "emits insert ops with returned stream opts" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :stream_messages, %{"mode" => "ok_with_opts"})

      assert_receive {:patch, %PatchEnvelope{stream_ops: stream_ops}}, 1_000

      assert [
               %{op: "insert", at: 0, limit: -100, item_key: "messages-m1"},
               %{op: "insert", at: 0, limit: -100, item_key: "messages-m2"}
             ] = stream_ops

      assert %AsyncResult{status: :ok, result: true} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :ok, result: true}, Map.get(&1.assigns, :messages))
               ).assigns.messages

    end

    test "emits a reset op when the task returns reset stream opts" do
      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :stream_messages, %{"mode" => "ok_with_reset"})

      assert_receive {:patch, %PatchEnvelope{stream_ops: stream_ops}}, 1_000
      assert [%{op: "reset", stream: "messages"}, %{op: "insert"}, %{op: "insert"}] = stream_ops

      assert %AsyncResult{status: :ok, result: true} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :ok, result: true}, Map.get(&1.assigns, :messages))
               ).assigns.messages

    end

    test "writes failed on {:error, reason} and leaves the stream slot untouched" do
      attach_telemetry_handler!([:arbor, :async, :stop])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :stream_messages, %{"mode" => "error"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _measurements,
                      %{name: :messages, kind: :stream}},
                     1_000

      socket =
        await_root_socket_poll!(
          pid,
          &match?(
            %AsyncResult{status: :failed, reason: {:error, :rate_limited}},
            Map.get(&1.assigns, :messages)
          )
        )

      assert %AsyncResult{status: :failed, reason: {:error, :rate_limited}} =
               socket.assigns.messages

      assert %Stream.Slot{inserts: [], deletes: [], reset?: false} =
               root_stream_slot(pid, :messages)

    end

    test "marks invalid return values as failed" do
      attach_telemetry_handler!([:arbor, :async, :stop])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :stream_messages, %{"mode" => "bad_return"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _measurements,
                      %{name: :messages, kind: :stream}},
                     1_000

      socket =
        await_root_socket_poll!(
          pid,
          &match?(%AsyncResult{status: :failed}, Map.get(&1.assigns, :messages))
        )

      assert %AsyncResult{status: :failed, reason: {:exit, {:error, %ArgumentError{}, _stack}}} =
               socket.assigns.messages

      assert %Stream.Slot{inserts: [], deletes: [], reset?: false} =
               root_stream_slot(pid, :messages)

    end

    test "marks non-enumerable stream results as failed" do
      attach_telemetry_handler!([:arbor, :async, :stop])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :stream_messages, %{"mode" => "not_enumerable"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _measurements,
                      %{name: :messages, kind: :stream}},
                     1_000

      socket =
        await_root_socket_poll!(
          pid,
          &match?(%AsyncResult{status: :failed}, Map.get(&1.assigns, :messages))
        )

      assert %AsyncResult{status: :failed, reason: {:exit, {:error, %ArgumentError{}, _stack}}} =
               socket.assigns.messages

      assert %Stream.Slot{inserts: [], deletes: [], reset?: false} =
               root_stream_slot(pid, :messages)

    end

    test "marks raised stream tasks as failed" do
      attach_telemetry_handler!([:arbor, :async, :stop])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :stream_messages, %{"mode" => "raise"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _measurements,
                      %{name: :messages, kind: :stream}},
                     1_000

      socket =
        await_root_socket_poll!(
          pid,
          &match?(%AsyncResult{status: :failed}, Map.get(&1.assigns, :messages))
        )

      assert %AsyncResult{
               status: :failed,
               reason: {:exit, {:error, %RuntimeError{message: "boom"}, _stack}}
             } = socket.assigns.messages

    end

    test "marks exited stream tasks as failed" do
      attach_telemetry_handler!([:arbor, :async, :stop])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} = Server.command(pid, [], :stream_messages, %{"mode" => "exit"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _measurements,
                      %{name: :messages, kind: :stream}},
                     1_000

      socket =
        await_root_socket_poll!(
          pid,
          &match?(
            %AsyncResult{status: :failed, reason: {:exit, :boom}},
            Map.get(&1.assigns, :messages)
          )
        )

      assert %AsyncResult{status: :failed, reason: {:exit, :boom}} = socket.assigns.messages

    end

    test "cancel_async by name resolves the stream assign to failed" do
      attach_telemetry_handler!([:arbor, :async, :stop])

      pid = start!()
      flush_initial!()

      assert {:ok, _reply} =
               Server.command(pid, [], :stream_messages_blocked, %{"tag" => "cancel"})

      assert %AsyncResult{status: :loading} =
               await_root_socket!(
                 pid,
                 &match?(%AsyncResult{status: :loading}, Map.get(&1.assigns, :messages))
               ).assigns.messages

      assert {:ok, _reply} =
               Server.command(pid, [], :cancel_messages, %{"reason" => "user_navigated"})

      assert_receive {:telemetry, [:arbor, :async, :stop], _measurements,
                      %{name: :messages, kind: :stream}},
                     1_000

      socket =
        await_root_socket_poll!(
          pid,
          &match?(
            %AsyncResult{status: :failed, reason: {:exit, :user_navigated}},
            Map.get(&1.assigns, :messages)
          )
        )

      assert %AsyncResult{status: :failed, reason: {:exit, :user_navigated}} =
               socket.assigns.messages

      assert %Stream.Slot{inserts: [], deletes: [], reset?: false} =
               root_stream_slot(pid, :messages)

    end
  end

  defp start!(store \\ AsyncStore) do
    start_supervised!(
      {Server, {store, %{"page_id" => "p1", "test_pid" => self()}, %{transport_pid: self()}}}
    )
  end

  defp flush_initial! do
    assert_receive {:patch, %PatchEnvelope{base_version: 0, version: 1}}, 1_000
  end

  defp await_root_socket!(pid, predicate, timeout \\ 1_000) when is_function(predicate, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_root_socket(pid, predicate, deadline)
  end

  defp await_root_socket_poll!(pid, predicate, timeout \\ 1_000) when is_function(predicate, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_root_socket_poll(pid, predicate, deadline)
  end

  defp do_await_root_socket(pid, predicate, deadline) do
    socket = root_socket(pid)

    if predicate.(socket) do
      socket
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("socket state did not settle: #{inspect(socket.assigns)}")
      end

      receive do
        {:patch, _envelope} -> do_await_root_socket(pid, predicate, deadline)
      after
        remaining ->
          flunk("socket state did not settle: #{inspect(socket.assigns)}")
      end
    end
  end

  defp root_socket(pid) do
    state = :sys.get_state(pid)
    %StoreRegistry.Entry{socket: socket} = StoreRegistry.get(state.store_registry, [])
    socket
  end

  defp do_await_root_socket_poll(pid, predicate, deadline) do
    socket = root_socket(pid)

    if predicate.(socket) do
      socket
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("socket state did not settle: #{inspect(socket.assigns)}")
      end

      receive do
      after
        min(remaining, 10) ->
          do_await_root_socket_poll(pid, predicate, deadline)
      end
    end
  end

  defp root_stream_slot(pid, name) do
    root_socket(pid).assigns[Stream.assigns_key()][name]
  end

  defp continue_task!(prefix, tag) do
    key = {prefix, tag}
    assert_receive {:task_ready, ^key, task_pid}, 1_000
    send(task_pid, {:continue_task, key})
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
