defmodule Arbor.AsyncSupervisor do
  @moduledoc """
  `Task.Supervisor` that hosts every async task spawned by
  `Arbor.Async.assign_async/3,4`, `Arbor.Async.start_async/3,4`, and
  `Arbor.Async.stream_async/3,4`.

  Started automatically by `Arbor.Application`. Applications that want to
  isolate a runtime under a different supervisor can pass `:supervisor` to
  any of the async entry points; the override must be the registered name
  of an already-started `Task.Supervisor`.

  Tasks are launched via `Task.Supervisor.async_nolink/3` so a task crash
  surfaces as a `{:DOWN, ref, :process, pid, reason}` message on the page
  server (and is converted to `Arbor.AsyncResult.failed(prior, {:exit, reason})`)
  rather than crashing the runtime.
  """

  @doc "Returns the child spec used by `Arbor.Application` to start the supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Task.Supervisor.child_spec(name: __MODULE__)
  end
end
