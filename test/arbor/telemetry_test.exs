defmodule Arbor.TelemetryTest do
  use ExUnit.Case, async: true

  alias Arbor.Telemetry

  describe "events/0" do
    test "covers every event documented in the PRD §Telemetry table" do
      names = MapSet.new(Telemetry.events(), fn {name, _desc} -> name end)

      required = [
        [:arbor, :command, :start],
        [:arbor, :command, :stop],
        [:arbor, :command, :exception],
        [:arbor, :render, :stop],
        [:arbor, :resolve, :stop],
        [:arbor, :validate, :stop],
        [:arbor, :validate, :exception],
        [:arbor, :diff, :stop],
        [:arbor, :patch, :stop],
        [:arbor, :stream, :flush],
        [:arbor, :async, :start],
        [:arbor, :async, :stop],
        [:arbor, :async, :exception],
        [:arbor, :async, :cancel],
        [:arbor, :async, :lazy_discard],
        [:arbor, :pubsub, :receive],
        [:arbor, :auth, :deny]
      ]

      for event <- required do
        assert event in names, "expected #{inspect(event)} in Arbor.Telemetry.events/0"
      end
    end

    test "every event entry has a non-empty description" do
      Enum.each(Telemetry.events(), fn {name, desc} ->
        assert is_list(name) and Enum.all?(name, &is_atom/1),
               "malformed event name: #{inspect(name)}"

        assert is_binary(desc) and desc != "", "missing description for #{inspect(name)}"
      end)
    end
  end
end
