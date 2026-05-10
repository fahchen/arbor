defmodule Arbor.Hooks.ValidateRenderTest do
  use ExUnit.Case, async: true

  alias Arbor.Hooks.ValidateRender
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

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{user_name: "Alice", avatar_url: nil}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule TitleStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :title, String.t()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{title: "Inbox"}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule NullableStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :avatar_url, String.t() | nil
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{avatar_url: nil}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule VariantStore do
    @moduledoc false

    use Arbor.Store

    state do
      field :status, %{type: :active} | %{type: :paused, value: integer()}
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{status: %{type: :active}}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule HeaderContainerStore do
    @moduledoc false

    use Arbor.Store

    alias Arbor.Hooks.ValidateRenderTest.HeaderStore

    state do
      field :header, HeaderStore.state()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{header: %{user_name: "Alice", avatar_url: nil}}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  test "Scenario: Invalid output is rejected before diffing" do
    assert {:error, [{"$.title", message}]} =
             ValidateRender.validate(%{"title" => 42}, TitleStore)

    assert message =~ "expected String.t(), got: 42"
  end

  test "Scenario: Null value is encoded as JSON null" do
    assert {:error, [{"$.avatar_url", "missing required field"}]} =
             ValidateRender.validate(%{}, NullableStore)

    assert :ok = ValidateRender.validate(%{"avatar_url" => nil}, NullableStore)
  end

  test "Scenario: Discriminated union codegen" do
    assert :ok =
             ValidateRender.validate(%{"status" => %{"type" => "active"}}, VariantStore)

    assert :ok =
             ValidateRender.validate(
               %{"status" => %{"type" => "paused", "value" => 3}},
               VariantStore
             )
  end

  test "Scenario: A state module is not a store" do
    assert true = Arbor.State.runtime_module?(MoneyState)
    refute Arbor.State.runtime_module?(HeaderStore)
  end

  test "Scenario: Raw map populates the field without mounting a child store" do
    assert :ok =
             ValidateRender.validate(
               %{"header" => %{"user_name" => "Alice", "avatar_url" => nil}},
               HeaderContainerStore
             )
  end

  test "Scenario: child placeholder populates the field by mounting a child store" do
    # Track A substitutes the child placeholder before this hook runs, so validation
    # sees the same wire-form map shape as the raw-map scenario.
    assert :ok =
             ValidateRender.validate(
               %{"header" => %{"user_name" => "Alice", "avatar_url" => nil}},
               HeaderContainerStore
             )
  end

  test "Scenario: runtime store id metadata is ignored during validation" do
    assert :ok =
             ValidateRender.validate(
               %{
                 "header" => %{
                   "user_name" => "Alice",
                   "avatar_url" => nil,
                   "__arbor_store_id__" => ["header"]
                 },
                 "__arbor_store_id__" => []
               },
               HeaderContainerStore
             )
  end

  test "Scenario: Validation exception telemetry is emitted before raise mode raises" do
    socket = %Socket{module: TitleStore, assigns: %{}, private: %{}}
    attach_telemetry_handler(self())

    assert_raise ArgumentError, ~r/\$\.title/, fn ->
      ValidateRender.after_serialize(:raise, %{"title" => 42}, socket)
    end

    assert_receive {:telemetry_event, [:arbor, :validate, :exception], %{count: 1}, metadata}

    assert %{store_module: TitleStore, errors: [{"$.title", _msg} | _rest]} = metadata
  end

  test "Scenario: telemetry validation mode reports errors without raising" do
    socket = %Socket{module: TitleStore, assigns: %{}, private: %{}}
    attach_telemetry_handler(self())

    assert {:cont, ^socket} =
             ValidateRender.after_serialize(:telemetry, %{"title" => 42}, socket)

    assert_receive {:telemetry_event, [:arbor, :validate, :exception], %{count: 1}, metadata}

    assert %{store_module: TitleStore, errors: [{"$.title", _msg} | _rest]} = metadata
  end

  test "Scenario: successful validation emits stop telemetry" do
    socket = %Socket{module: TitleStore, assigns: %{}, private: %{}}
    attach_telemetry_handler(self())

    assert {:cont, ^socket} =
             ValidateRender.after_serialize(:raise, %{"title" => "Inbox"}, socket)

    assert_receive {:telemetry_event, [:arbor, :validate, :stop], %{count: 1}, metadata}
    assert %{store_module: TitleStore, errors: []} = metadata
  end

  defp attach_telemetry_handler(test_pid) do
    handler_id = "validate-render-#{System.unique_integer([:positive, :monotonic])}"

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
