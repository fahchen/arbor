defmodule Arbor.Hooks.ValidateCommandSchemaTest do
  use ExUnit.Case, async: true

  alias Arbor.Hooks.ValidateCommandSchema
  alias Arbor.Socket

  defmodule TargetStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :query, String.t()
    end

    command :change_query do
      payload :query, String.t()
    end

    command :no_payload

    def to_state(socket), do: %{query: Map.get(socket.assigns, :query, "")}
  end

  defmodule HostStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    def to_state(_socket), do: %{ok: true}
  end

  describe "Scenario: Payload conforms to the declared schema" do
    test "validates a string payload field successfully" do
      socket = host_socket_targeting(TargetStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(
                 :change_query,
                 %{"query" => "shirt"},
                 socket
               )
    end

    test "accepts an atom-keyed payload as well" do
      socket = host_socket_targeting(TargetStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(
                 :change_query,
                 %{query: "shirt"},
                 socket
               )
    end

    test "no payload command continues without raising" do
      socket = host_socket_targeting(TargetStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(:no_payload, %{}, socket)
    end
  end

  describe "Scenario: Payload violates a declared field type" do
    test "type-mismatch raises ArgumentError before the handler runs" do
      socket = host_socket_targeting(TargetStore)

      assert_raise ArgumentError, ~r/change_query.*query: expected String\.t\(\)/s, fn ->
        ValidateCommandSchema.before_command(
          :change_query,
          %{"query" => 42},
          socket
        )
      end
    end

    test "missing field raises ArgumentError" do
      socket = host_socket_targeting(TargetStore)

      assert_raise ArgumentError, ~r/missing required field/, fn ->
        ValidateCommandSchema.before_command(:change_query, %{}, socket)
      end
    end
  end

  describe "Unknown commands fall through" do
    test "unknown command name on the addressed module is a no-op" do
      socket = host_socket_targeting(TargetStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(:not_declared, %{}, socket)
    end

    test "no addressed module configured falls back to socket module" do
      socket = %Socket{module: TargetStore, assigns: %{}, private: %{}}

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(
                 :change_query,
                 %{"query" => "shirt"},
                 socket
               )
    end
  end

  test "successful validation emits [:arbor, :validate, :command, :stop]" do
    handler_id = "validate-command-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :validate, :command, :stop],
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    socket = host_socket_targeting(TargetStore)

    assert {:cont, ^socket} =
             ValidateCommandSchema.before_command(
               :change_query,
               %{"query" => "shirt"},
               socket
             )

    assert_receive {:telemetry_event, [:arbor, :validate, :command, :stop], %{count: 1},
                    %{store_module: TargetStore, command: :change_query}}
  end

  defp host_socket_targeting(target_module) do
    Socket.put_private(
      %Socket{module: HostStore, assigns: %{}, private: %{}},
      ValidateCommandSchema.target_private_key(),
      target_module
    )
  end
end
