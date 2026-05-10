defmodule Arbor.Telemetry do
  @moduledoc """
  Telemetry emission helper for Arbor runtime events plus the canonical event
  catalog.

  `events/0` returns every event name emitted by the runtime, paired with a
  one-line description. Use it to attach a single handler to all Arbor events
  (e.g. for log-shipping, metrics aggregation, or test observation):

      Arbor.Telemetry.events()
      |> Enum.map(&elem(&1, 0))
      |> :telemetry.attach_many("arbor-collector", &MyTelemetry.handle_event/4, nil)
  """

  @typedoc "One Arbor telemetry event entry: `{event_name, description}`."
  @type event() :: {[atom()], String.t()}

  @events [
    {[:arbor, :command, :start], "Per-command span start. Metadata: page_id, store_id, command."},
    {[:arbor, :command, :stop],
     "Per-command span stop. Measurements: duration. Metadata: page_id, store_id, command, status."},
    {[:arbor, :command, :exception],
     "Per-command span when a handler raises. Metadata: page_id, store_id, command, kind, reason, stacktrace."},
    {[:arbor, :render, :stop],
     "Render cycle completion. Measurements: duration. Metadata: module."},
    {[:arbor, :resolve, :stop],
     "Render-output placeholder resolution completion. Measurements: duration."},
    {[:arbor, :validate, :stop],
     "Render-output validation pass. Measurements: duration. Metadata: module, status."},
    {[:arbor, :validate, :exception],
     "Render-output validation failure. Metadata: kind, reason, stacktrace."},
    {[:arbor, :diff, :stop], "JSON Patch diff completion. Measurements: duration, op_count."},
    {[:arbor, :patch, :stop],
     "Patch envelope built. Measurements: count, stream_count. Metadata: module, version."},
    {[:arbor, :stream, :flush], "Stream pending-ops flushed for one entry. Measurements: count."},
    {[:arbor, :async, :start],
     "Async task started via `assign_async`/`start_async`/`stream_async`."},
    {[:arbor, :async, :stop], "Async task completed (`:ok` or `:failed`)."},
    {[:arbor, :async, :exception], "Async task crashed or `handle_async/3` raised (BDR-0020)."},
    {[:arbor, :async, :cancel], "`cancel_async/2,3` invoked for a tracked task."},
    {[:arbor, :async, :lazy_discard],
     "Late async result arrived after tracking was dropped (BDR-0019)."},
    {[:arbor, :pubsub, :receive],
     "`handle_info/2` dispatched on the root store; observability for app PubSub messages (BDR-0005)."},
    {[:arbor, :auth, :deny],
     "A `:before_command` hook returned `{:halt, reply, socket}` — graceful authorization denial (BDR-0008)."}
  ]

  @doc """
  Emits a telemetry event when the `:telemetry` module is available.

  ## Examples

      iex> Arbor.Telemetry.emit([:arbor, :render, :stop], %{duration: 10}, %{module: Example})
      :ok
  """
  @spec emit([atom()], map(), map()) :: :ok
  def emit(event_name, measurements, metadata)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(event_name, measurements, metadata)
    end

    :ok
  end

  @doc """
  Returns every telemetry event the Arbor runtime emits along with a one-line
  description.

  ## Examples

      iex> [{[:arbor, :command, :start], _desc} | _rest] = Arbor.Telemetry.events()
  """
  @spec events() :: [event()]
  def events, do: @events
end
