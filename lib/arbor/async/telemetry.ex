defmodule Arbor.Async.Telemetry do
  @moduledoc """
  Canonical telemetry-event emitters for the async lifecycle.

  Every event metadata map carries `page_id`, `store_id`, `name`, and
  `kind` so consumers can filter by page, store node, or async family
  without re-deriving them. `store_id` is the runtime identity of the
  store node — the array of local ids from root, equivalent to
  `Arbor.Socket.store_id/1`. `Arbor.Telemetry.emit/3` is the underlying
  call — it is a no-op when `:telemetry` is not loaded.
  """

  alias Arbor.Async
  alias Arbor.Socket
  alias Arbor.Telemetry

  @typedoc "Async name surfaced on the wire/telemetry."
  @type name() :: Async.tracking_name()

  @doc "Emits `[:arbor, :async, :start]`."
  @spec start(Socket.t(), name(), Async.kind()) :: :ok
  def start(socket, name, kind) do
    Telemetry.emit(
      [:arbor, :async, :start],
      %{system_time: System.system_time()},
      base_metadata(socket, name, kind)
    )
  end

  @doc "Emits `[:arbor, :async, :stop]`."
  @spec stop(Socket.t(), name(), Async.kind(), atom()) :: :ok
  def stop(socket, name, kind, status) when status in [:ok, :failed] do
    Telemetry.emit(
      [:arbor, :async, :stop],
      %{system_time: System.system_time()},
      Map.put(base_metadata(socket, name, kind), :status, status)
    )
  end

  @doc "Emits `[:arbor, :async, :exception]`."
  @spec exception(
          Socket.t(),
          name(),
          Async.kind(),
          :error | :exit | :throw,
          term(),
          Exception.stacktrace()
        ) ::
          :ok
  def exception(socket, name, kind, exception_kind, reason, stacktrace) do
    Telemetry.emit(
      [:arbor, :async, :exception],
      %{system_time: System.system_time()},
      Map.merge(base_metadata(socket, name, kind), %{
        # `:kind` carries the async family (`:assign | :start | :stream`) per
        # `base_metadata/3`. The catch classifier (`:error | :exit | :throw`)
        # is exposed as a separate key to avoid clobbering it.
        exception_kind: exception_kind,
        reason: reason,
        stacktrace: stacktrace
      })
    )
  end

  @doc "Emits `[:arbor, :async, :cancel]`."
  @spec cancel(Socket.t(), name(), Async.kind(), term()) :: :ok
  def cancel(socket, name, kind, reason) do
    Telemetry.emit(
      [:arbor, :async, :cancel],
      %{system_time: System.system_time()},
      Map.put(base_metadata(socket, name, kind), :reason, reason)
    )
  end

  @doc "Emits `[:arbor, :async, :lazy_discard]`."
  @spec lazy_discard(map(), name() | nil, Async.kind() | nil) :: :ok
  def lazy_discard(metadata, name, kind) do
    Telemetry.emit(
      [:arbor, :async, :lazy_discard],
      %{system_time: System.system_time()},
      metadata
      |> Map.put(:name, name)
      |> Map.put(:kind, kind)
    )
  end

  @doc false
  @spec base_metadata(Socket.t(), name(), Async.kind()) :: map()
  def base_metadata(%Socket{} = socket, name, kind) do
    %{
      page_id: page_id(socket),
      store_id: Socket.store_id(socket),
      module: socket.module,
      name: name,
      kind: kind
    }
  end

  defp page_id(%Socket{assigns: assigns}) do
    Map.get(assigns, :page_id) || Map.get(assigns, "page_id")
  end
end
