defmodule Arbor.Telemetry do
  @moduledoc """
  Optional telemetry emission helper for Arbor runtime events.
  """

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
end
