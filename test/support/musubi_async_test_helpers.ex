defmodule Musubi.AsyncTestHelpers do
  @moduledoc """
  Deterministic timing helpers for `Musubi.Async` and `Musubi.Page.Server` tests.

  The contract: every async task body in test stores wraps its real work
  with `instrument/2`, which sends `{@started_msg, task_pid}` to the
  registered observer pid (typically the test process) before running.
  Tests then drive timing through three primitives instead of polling:

    * `await_task!/1` — confirm one instrumented task spawned and exited
    * `receive_task_pid!/1` — observe a task's spawn without waiting for exit
      (use when the task body is intentionally blocked so the test can
      assert on the loading state before releasing it)
    * `sync_server!/1` — drain a `GenServer`'s mailbox via `:sys.get_state/1`,
      so any `{ref, result}`/`:DOWN`/`handle_continue` pending after the
      task finished are processed before the test reads state

  No fixed sleeps, no polling loops, no fuzzy `assert_receive` timeouts on
  patches and telemetry — receive after sync is immediate.
  """

  import ExUnit.Assertions

  @started_msg :__musubi_test_task_started__

  @default_timeout 200

  @doc "The marker atom sent by `instrument/2` to announce a spawned task."
  @spec started_msg() :: :__musubi_test_task_started__
  def started_msg, do: @started_msg

  @doc """
  Wraps a 0-arity task fn so the spawned task's pid is observable from
  `observer`.

  The wrapper sends `{started_msg(), self()}` before running the underlying
  fn, so callers can monitor the task pid for `:DOWN` or send messages back
  into the task body (the latter is how loading-state tests release a
  blocked task — the body explicitly `receive`s a continuation message).
  """
  @spec instrument(pid(), (-> term())) :: (-> term())
  def instrument(observer, fun) when is_pid(observer) and is_function(fun, 0) do
    fn ->
      send(observer, {@started_msg, self()})
      fun.()
    end
  end

  @doc """
  Confirms one instrumented task spawned and ran to termination.

  Equivalent to `receive_task_pid!/1` followed by `Process.monitor/1` and an
  `assert_receive` on the matching `:DOWN`. Use for tasks that finish on
  their own (no test-driven release).
  """
  @spec await_task!(timeout()) :: :ok
  def await_task!(timeout \\ @default_timeout) do
    task_pid = receive_task_pid!(timeout)
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, _, _, _reason}, timeout
    :ok
  end

  @doc """
  Returns the next instrumented task's pid without waiting for its exit.

  Use for tasks whose body intentionally blocks (e.g. inside a `receive`)
  so the test can observe the loading state and then send a continuation
  message into the task to let it complete.
  """
  @spec receive_task_pid!(timeout()) :: pid()
  def receive_task_pid!(timeout \\ @default_timeout) do
    assert_receive {@started_msg, task_pid}, timeout
    task_pid
  end

  @doc """
  Drains a `GenServer`'s mailbox by issuing a synchronous `:sys.get_state/1`
  call. Returns `:ok`.

  All messages already queued in the GenServer's mailbox at call time
  (`{ref, result}` from a finished task, the matching `:DOWN`, and any
  `handle_continue` pending from those) are processed before the sys
  request returns. Calling this after `await_task!/1` is the deterministic
  equivalent of "wait for the page server to settle on the task result".
  """
  @spec sync_server!(GenServer.server()) :: :ok
  def sync_server!(server) do
    _state = :sys.get_state(server)
    :ok
  end
end
