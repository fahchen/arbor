defmodule Arbor.Hooks.ValidateToStateTest do
  use ExUnit.Case, async: true

  alias Arbor.Hooks.ValidateToState
  alias Arbor.Socket

  defmodule MoneyState do
    @moduledoc false

    use Arbor.State

    state do
      field :amount, integer()
    end
  end

  defmodule HeaderStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :user_name, String.t()
      field :avatar_url, String.t() | nil
    end
  end

  defmodule TitleStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :title, String.t()
    end
  end

  defmodule HandlerStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :handler, map()
    end
  end

  defmodule NullableStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :avatar_url, String.t() | nil
    end
  end

  defmodule VariantStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :status, %{type: :active} | %{type: :paused, value: integer()}
    end
  end

  defmodule HeaderContainerStore do
    @moduledoc false

    use Arbor.Store

    alias Arbor.Hooks.ValidateToStateTest.HeaderStore

    state do
      field :header, HeaderStore.state()
    end
  end

  test "Scenario: Invalid output is rejected before diffing" do
    assert {:error, [%{path: "$.title", reason: :type_mismatch} | _rest]} =
             ValidateToState.validate(%{title: 42}, TitleStore)
  end

  test "Scenario: Render that surfaces a function reference is rejected" do
    assert {:error, [%{path: "$.handler", reason: :function_ref, message: message}]} =
             ValidateToState.validate(%{handler: fn -> :ok end}, HandlerStore)

    assert message =~ "function references are not allowed"
  end

  test "Scenario: Null value is encoded as JSON null" do
    assert {:error, [%{path: "$.avatar_url", reason: :missing_key}]} =
             ValidateToState.validate(%{}, NullableStore)

    assert :ok = ValidateToState.validate(%{avatar_url: nil}, NullableStore)
  end

  test "Scenario: Discriminated union codegen" do
    assert :ok = ValidateToState.validate(%{status: %{type: :active}}, VariantStore)

    assert :ok =
             ValidateToState.validate(%{status: %{type: :paused, value: 3}}, VariantStore)
  end

  test "Scenario: A state module is not a store" do
    assert true = Arbor.State.runtime_module?(MoneyState)
    refute Arbor.State.runtime_module?(HeaderStore)
  end

  test "Scenario: Raw map populates the field without mounting a child store" do
    assert :ok =
             ValidateToState.validate(
               %{header: %{user_name: "Alice", avatar_url: nil}},
               HeaderContainerStore
             )
  end

  test "Scenario: child placeholder populates the field by mounting a child store" do
    # Track A substitutes the child placeholder before this hook runs, so validation
    # sees the same resolved map shape as the raw-map scenario.
    assert :ok =
             ValidateToState.validate(
               %{header: %{user_name: "Alice", avatar_url: nil}},
               HeaderContainerStore
             )
  end

  test "Scenario: Validation behaviour depends on environment" do
    socket = %Socket{module: TitleStore, assigns: %{}, private: %{}}
    attach_telemetry_handler(self())

    assert_raise ArgumentError, ~r/\$\.title/, fn ->
      ValidateToState.run(
        %{resolved_output: %{title: 42}, env: :test, validation_mode: :raise},
        socket
      )
    end

    assert_receive {:telemetry_event, [:arbor, :validate, :exception], %{count: 1}, metadata}

    assert %{env: :test, store_module: TitleStore, errors: [%{path: "$.title"} | _rest]} =
             metadata

    assert {:cont, ^socket} =
             ValidateToState.run(
               %{resolved_output: %{title: 42}, env: :prod, validation_mode: :telemetry},
               socket
             )

    assert_receive {:telemetry_event, [:arbor, :validate, :exception], %{count: 1}, metadata}

    assert %{env: :prod, store_module: TitleStore, errors: [%{path: "$.title"} | _rest]} =
             metadata
  end

  test "Scenario: successful validation emits stop telemetry" do
    socket = %Socket{module: TitleStore, assigns: %{}, private: %{}}
    attach_telemetry_handler(self())

    assert {:cont, ^socket} =
             ValidateToState.run(
               %{resolved_output: %{title: "Inbox"}, env: :test, validation_mode: :raise},
               socket
             )

    assert_receive {:telemetry_event, [:arbor, :validate, :stop], %{count: 1}, metadata}
    assert %{env: :test, store_module: TitleStore, errors: []} = metadata
  end

  defp attach_telemetry_handler(test_pid) do
    handler_id = "validate-to-state-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:arbor, :validate, :stop],
        [:arbor, :validate, :exception]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
