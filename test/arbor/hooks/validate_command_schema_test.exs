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

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(socket), do: %{query: Map.get(socket.assigns, :query, "")}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule HostStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{ok: true}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
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

  defmodule AddressInput do
    @moduledoc false
    use Arbor.Input

    input do
      field :line1, String.t()
      field :city, String.t()
    end
  end

  defmodule UserInput do
    @moduledoc false
    use Arbor.Input

    input do
      field :name, String.t()
      field :age, integer()
      field :address, AddressInput.t()
    end
  end

  defmodule UserState do
    @moduledoc false
    use Arbor.State

    state do
      field :name, String.t()
      field :age, integer()
    end
  end

  defmodule NestedInputStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    command :create_user do
      payload :user, UserInput.t()
    end

    command :touch_state do
      payload :user, UserState.t()
    end

    command :create_literal do
      payload :user, %{name: String.t(), age: integer()}
    end

    command :set_status do
      payload :status, %{type: :active} | %{type: :paused, value: integer()}
    end

    command :tag do
      payload :tags, list(String.t())
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(_socket), do: %{ok: true}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  describe "nested data structures" do
    test "Arbor.Input nested payload — happy path" do
      socket = host_socket_targeting(NestedInputStore)

      payload = %{
        "user" => %{
          "name" => "Alice",
          "age" => 30,
          "address" => %{"line1" => "1 Way", "city" => "Town"}
        }
      }

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(:create_user, payload, socket)
    end

    test "Arbor.Input nested payload — missing key" do
      socket = host_socket_targeting(NestedInputStore)

      payload = %{"user" => %{"name" => "Alice", "age" => 30}}

      assert_raise ArgumentError, ~r/create_user.*user.*expected/s, fn ->
        ValidateCommandSchema.before_command(:create_user, payload, socket)
      end
    end

    test "Arbor.Input nested payload — wrong type" do
      socket = host_socket_targeting(NestedInputStore)

      payload = %{
        "user" => %{
          "name" => "Alice",
          "age" => "thirty",
          "address" => %{"line1" => "1 Way", "city" => "Town"}
        }
      }

      assert_raise ArgumentError, ~r/create_user.*user.*expected/s, fn ->
        ValidateCommandSchema.before_command(:create_user, payload, socket)
      end
    end

    test "Arbor.State nested payload (cross-type compatibility)" do
      socket = host_socket_targeting(NestedInputStore)

      payload = %{"user" => %{"name" => "Alice", "age" => 30}}

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(:touch_state, payload, socket)
    end

    test "literal-keyed map payload — happy path" do
      socket = host_socket_targeting(NestedInputStore)

      payload = %{"user" => %{"name" => "Alice", "age" => 30}}

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(:create_literal, payload, socket)
    end

    test "literal-keyed map payload — missing key" do
      socket = host_socket_targeting(NestedInputStore)

      assert_raise ArgumentError, ~r/create_literal.*user/s, fn ->
        ValidateCommandSchema.before_command(
          :create_literal,
          %{"user" => %{"name" => "Alice"}},
          socket
        )
      end
    end

    test "union of literal-tagged maps — :active branch" do
      socket = host_socket_targeting(NestedInputStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(
                 :set_status,
                 %{"status" => %{"type" => "active"}},
                 socket
               )
    end

    test "union of literal-tagged maps — :paused branch" do
      socket = host_socket_targeting(NestedInputStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(
                 :set_status,
                 %{"status" => %{"type" => "paused", "value" => 7}},
                 socket
               )
    end

    test "union of literal-tagged maps — neither branch" do
      socket = host_socket_targeting(NestedInputStore)

      assert_raise ArgumentError, ~r/set_status/, fn ->
        ValidateCommandSchema.before_command(
          :set_status,
          %{"status" => %{"type" => "stopped"}},
          socket
        )
      end
    end

    test "list(String.t()) payload" do
      socket = host_socket_targeting(NestedInputStore)

      assert {:cont, ^socket} =
               ValidateCommandSchema.before_command(
                 :tag,
                 %{"tags" => ["a", "b"]},
                 socket
               )

      assert_raise ArgumentError, ~r/tag.*tags/s, fn ->
        ValidateCommandSchema.before_command(
          :tag,
          %{"tags" => ["a", 1]},
          socket
        )
      end
    end

    test "nested input within input — recursion check" do
      socket = host_socket_targeting(NestedInputStore)

      payload = %{
        "user" => %{
          "name" => "Alice",
          "age" => 30,
          "address" => %{"line1" => "1 Way", "city" => 99}
        }
      }

      assert_raise ArgumentError, ~r/create_user.*user/s, fn ->
        ValidateCommandSchema.before_command(:create_user, payload, socket)
      end
    end
  end

  defp host_socket_targeting(target_module) do
    Socket.put_private(
      %Socket{module: HostStore, assigns: %{}, private: %{}},
      ValidateCommandSchema.target_private_key(),
      target_module
    )
  end
end
