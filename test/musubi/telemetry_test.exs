defmodule Musubi.TelemetryTest do
  use ExUnit.Case, async: true

  alias Musubi.Telemetry

  describe "events/0" do
    test "covers every event documented in the PRD §Telemetry table" do
      names = MapSet.new(Telemetry.events(), fn {name, _desc} -> name end)

      required = [
        [:musubi, :command, :start],
        [:musubi, :command, :stop],
        [:musubi, :command, :exception],
        [:musubi, :render, :stop],
        [:musubi, :resolve, :stop],
        [:musubi, :validate, :stop],
        [:musubi, :validate, :exception],
        [:musubi, :diff, :stop],
        [:musubi, :patch, :stop],
        [:musubi, :stream, :flush],
        [:musubi, :async, :start],
        [:musubi, :async, :stop],
        [:musubi, :async, :exception],
        [:musubi, :async, :cancel],
        [:musubi, :async, :lazy_discard],
        [:musubi, :pubsub, :receive],
        [:musubi, :auth, :deny]
      ]

      for event <- required do
        assert event in names, "expected #{inspect(event)} in Musubi.Telemetry.events/0"
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
