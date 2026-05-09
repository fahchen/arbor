defmodule Arbor.AsyncTest do
  use ExUnit.Case, async: true

  alias Arbor.Async
  alias Arbor.AsyncResult
  alias Arbor.Socket

  # `Arbor.AsyncSupervisor` is started by `Arbor.Application` at app boot.

  describe "assign_async/3 single-key" do
    test "writes loading immediately and tracks the task" do
      socket = base_socket()
      socket = Async.assign_async(socket, :profile, fn -> {:ok, %{name: "ada"}} end)

      assert %AsyncResult{status: :loading, result: nil, reason: nil} = socket.assigns.profile

      tracking = Async.tracking(socket)
      assert %{profile: %{kind: :assign, keys: [:profile], ref: ref}} = tracking
      assert is_reference(ref)
    end

    test "applying ok result writes AsyncResult.ok" do
      socket = base_socket()
      socket = Async.assign_async(socket, :profile, fn -> {:ok, %{name: "ada"}} end)
      {classified, entry} = await_task(socket, :profile)

      socket = Async.apply_task_result(socket, :profile, entry, classified)

      assert %AsyncResult{status: :ok, result: %{name: "ada"}, reason: nil} =
               socket.assigns.profile

      assert Async.tracking(socket) == %{}
    end

    test "applying error result writes AsyncResult.failed with prior preserved" do
      socket = Socket.assign(base_socket(), :profile, AsyncResult.ok(nil, "snapshot"))
      socket = Async.assign_async(socket, :profile, fn -> {:error, :unauthorized} end)
      {classified, entry} = await_task(socket, :profile)

      socket = Async.apply_task_result(socket, :profile, entry, classified)

      assert %AsyncResult{status: :failed, result: "snapshot", reason: {:error, :unauthorized}} =
               socket.assigns.profile
    end

    test "raised exception classifies as failed {:exit, ...}" do
      socket = base_socket()
      socket = Async.assign_async(socket, :profile, fn -> raise "boom" end)
      {classified, entry} = await_task(socket, :profile)

      socket = Async.apply_task_result(socket, :profile, entry, classified)

      assert %AsyncResult{status: :failed, reason: {:exit, {:error, %RuntimeError{}, _stack}}} =
               socket.assigns.profile
    end

    test "thrown value classifies as failed {:exit, {{:nocatch, ...}, ...}}" do
      socket = base_socket()
      socket = Async.assign_async(socket, :profile, fn -> throw(:bail) end)
      {classified, entry} = await_task(socket, :profile)

      socket = Async.apply_task_result(socket, :profile, entry, classified)

      assert %AsyncResult{status: :failed, reason: {:exit, {{:nocatch, :bail}, _stack}}} =
               socket.assigns.profile
    end

    test "preserves prior result during reload (no :reset)" do
      prior = AsyncResult.ok(nil, "snapshot")

      socket =
        base_socket()
        |> Socket.assign(:profile, prior)
        |> Async.assign_async(:profile, fn -> {:ok, "fresh"} end)

      assert %AsyncResult{status: :loading, result: "snapshot", reason: nil} =
               socket.assigns.profile
    end

    test ":reset re-emits loading without prior" do
      prior = AsyncResult.ok(nil, "snapshot")

      socket =
        base_socket()
        |> Socket.assign(:profile, prior)
        |> Async.assign_async(:profile, fn -> {:ok, "fresh"} end, reset: true)

      assert %AsyncResult{status: :loading, result: nil, reason: nil} = socket.assigns.profile
    end
  end

  describe "assign_async/3 multi-key" do
    test "writes loading for every key and resolves atomically" do
      socket =
        Async.assign_async(base_socket(), [:user, :org], fn -> {:ok, %{user: "u", org: "o"}} end)

      assert %AsyncResult{status: :loading} = socket.assigns.user
      assert %AsyncResult{status: :loading} = socket.assigns.org

      {classified, entry} = await_task(socket, [:user, :org])

      socket = Async.apply_task_result(socket, [:user, :org], entry, classified)
      assert %AsyncResult{status: :ok, result: "u"} = socket.assigns.user
      assert %AsyncResult{status: :ok, result: "o"} = socket.assigns.org
    end

    test ":reset subset only resets the listed keys" do
      socket =
        base_socket()
        |> Socket.assign(:user, AsyncResult.ok(nil, "u_prior"))
        |> Socket.assign(:org, AsyncResult.ok(nil, "o_prior"))
        |> Async.assign_async([:user, :org], fn -> {:ok, %{user: "u", org: "o"}} end,
          reset: [:user]
        )

      assert %AsyncResult{status: :loading, result: nil} = socket.assigns.user
      assert %AsyncResult{status: :loading, result: "o_prior"} = socket.assigns.org
    end
  end

  describe "start_async/3" do
    test "writes nothing to assigns by default" do
      socket = base_socket()
      socket = Async.start_async(socket, :warm_cache, fn -> :ok end)

      refute Map.has_key?(socket.assigns, :warm_cache)
      assert %{warm_cache: %{kind: :start, keys: nil}} = Async.tracking(socket)
    end

    test "second call with same name silently overwrites tracking; old result lazy-discards" do
      socket = base_socket()
      socket = Async.start_async(socket, :foo, fn -> :a end)
      first_ref = Async.tracking(socket).foo.ref

      socket = Async.start_async(socket, :foo, fn -> :b end)
      second_ref = Async.tracking(socket).foo.ref

      refute first_ref == second_ref
      assert is_reference(second_ref)
    end
  end

  describe "cancel_async/2,3 by name" do
    test "kills task and stamps cancel_reason; :DOWN drives failed write" do
      socket = base_socket()

      socket =
        Async.assign_async(socket, :slow, fn ->
          Process.sleep(50_000)
          {:ok, :never}
        end)

      pid = Async.tracking(socket).slow.pid
      ref = Async.tracking(socket).slow.ref

      socket = Async.cancel_async(socket, :slow, :user_navigated_away)

      # cancel does not pre-write; tracking still present with cancel_reason
      assert %{slow: %{cancel_reason: :user_navigated_away}} = Async.tracking(socket)

      # :DOWN arrives because we killed pid with that reason
      assert_receive {:DOWN, ^ref, :process, ^pid, :user_navigated_away}, 1_000

      {:ok, entry} = Async.fetch_tracking(socket, :slow)
      socket = Async.apply_task_down(socket, :slow, entry, :user_navigated_away)

      assert %AsyncResult{status: :failed, reason: {:exit, :user_navigated_away}} =
               socket.assigns.slow
    end
  end

  describe "cancel_async/3 by AsyncResult variant" do
    test "pre-writes failed and drops tracking before killing the task" do
      socket = base_socket()

      socket =
        Async.assign_async(socket, :slow, fn ->
          Process.sleep(50_000)
          {:ok, :never}
        end)

      ar = socket.assigns.slow

      socket = Async.cancel_async(socket, ar, :user_navigated_away)

      assert %AsyncResult{status: :failed, reason: {:exit, :user_navigated_away}} =
               socket.assigns.slow

      # tracking already dropped
      assert Async.tracking(socket) == %{}
    end
  end

  describe "stream_async/3 enforcement" do
    test "raises when no stream slot is declared" do
      socket = base_socket()

      assert_raise ArgumentError, ~r/stream_async :messages/, fn ->
        Async.stream_async(socket, :messages, fn -> {:ok, []} end)
      end
    end
  end

  describe "supervisor override" do
    test ":supervisor option is honored" do
      sup_pid = start_supervised!(Task.Supervisor)

      socket = base_socket()
      socket = Async.assign_async(socket, :profile, fn -> {:ok, :v} end, supervisor: sup_pid)

      entry = Async.tracking(socket).profile
      assert entry.supervisor == sup_pid
    end
  end

  defp base_socket do
    %Socket{module: nil, parent_path: [], id: ""}
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
