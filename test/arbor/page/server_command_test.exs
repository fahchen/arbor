defmodule Arbor.Page.ServerCommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Arbor.Lifecycle
  alias Arbor.Page.Server
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry
  alias Arbor.Socket

  defmodule LeafStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :status, String.t()
    end

    command :select do
      payload :id, String.t()
    end

    def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :status, "ready")}
    def to_state(socket), do: %{status: socket.assigns.status}

    def handle_command(:select, %{"id" => id}, socket) do
      {:reply, %{selected: id}, Arbor.Socket.assign(socket, :status, "selected:" <> id)}
    end
  end

  defmodule FiltersStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :query, String.t()
    end

    command :change_query do
      payload :query, String.t()
    end

    command :wipe

    def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :query, "")}
    def to_state(socket), do: %{query: socket.assigns.query}

    def handle_command(:change_query, %{"query" => query}, socket) do
      {:noreply, Arbor.Socket.assign(socket, :query, query)}
    end

    def handle_command(:wipe, _payload, socket) do
      {:noreply, Arbor.Socket.assign(socket, :query, "")}
    end
  end

  defmodule RootStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :title, String.t()
      field :filters, FiltersStore.t()
      field :leaf, LeafStore.t()
    end

    command :reload_products

    def mount(socket) do
      socket =
        socket
        |> Arbor.Socket.assign(:title, "home")
        |> Arbor.Socket.assign(:reloads, 0)

      socket =
        case Arbor.Socket.get_private(socket, :hook_events) do
          nil -> socket
          test_pid -> attach_audit_hooks(socket, test_pid)
        end

      {:ok, socket}
    end

    def to_state(socket) do
      %{
        title: socket.assigns.title,
        filters: Arbor.Child.child(FiltersStore, id: "filters"),
        leaf: Arbor.Child.child(LeafStore, id: "leaf")
      }
    end

    def handle_command(:reload_products, _payload, socket) do
      next = Map.get(socket.assigns, :reloads, 0) + 1
      {:reply, %{reloaded: true}, Arbor.Socket.assign(socket, :reloads, next)}
    end

    defp attach_audit_hooks(socket, test_pid) do
      socket
      |> Lifecycle.attach_hook(:audit_before, :before_command, fn name, _payload, sock ->
        send(test_pid, {:hook, :root_before, name})
        {:cont, sock}
      end)
      |> Lifecycle.attach_hook(:audit_after, :after_command, fn name, _payload, sock ->
        send(test_pid, {:hook, :root_after, name})
        {:cont, sock}
      end)
    end
  end

  defmodule HaltingStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    command :restricted

    def mount(socket) do
      socket =
        Lifecycle.attach_hook(socket, :auth, :before_command, fn _name, _payload, sock ->
          {:halt, %{ok: false, reason: "unauthorized"}, sock}
        end)

      {:ok, Arbor.Socket.assign(socket, :ok, true)}
    end

    def to_state(socket), do: %{ok: socket.assigns.ok}

    def handle_command(:restricted, _payload, socket) do
      send(socket.assigns.test_pid, :handler_should_not_run)
      {:noreply, socket}
    end
  end

  defmodule SilentHaltStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    command :gated

    def mount(socket) do
      socket =
        Lifecycle.attach_hook(socket, :gate, :before_command, fn _name, _payload, sock ->
          {:halt, sock}
        end)

      {:ok, Arbor.Socket.assign(socket, :ok, true)}
    end

    def to_state(socket), do: %{ok: socket.assigns.ok}

    def handle_command(:gated, _payload, socket) do
      send(socket.assigns.test_pid, :handler_should_not_run)
      {:noreply, socket}
    end
  end

  defmodule ProductCardStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :id, String.t()
    end

    command :select

    def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :id, socket.id)}
    def to_state(socket), do: %{id: socket.assigns.id}

    def handle_command(:select, _payload, socket) do
      {:reply, %{selected: socket.assigns.id}, socket}
    end
  end

  defmodule ProductsListStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :products, list(ProductCardStore.t())
    end

    def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :ids, ["prod_123", "prod_456"])}

    def to_state(socket) do
      %{
        products:
          Enum.map(socket.assigns.ids, fn id -> Arbor.Child.child(ProductCardStore, id: id) end)
      }
    end
  end

  defmodule CrashingStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    command :boom

    def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :ok, true)}
    def to_state(socket), do: %{ok: socket.assigns.ok}

    def handle_command(:boom, _payload, _socket) do
      raise "boom"
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "Scenario: Routing to the root store" do
    test "dispatches the command to the root handler and returns the reply" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})

      assert {:ok, %{reloaded: true}} = Server.command(pid, [], :reload_products, %{})
    end
  end

  describe "Scenario: Routing to a nested child store" do
    test "dispatches command to filters child and persists the mutated socket" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})

      assert {:ok, %{}} =
               Server.command(pid, ["filters"], :change_query, %{"query" => "shirt"})

      %State{store_registry: registry} = :sys.get_state(pid)
      entry = StoreRegistry.get(registry, ["filters"])
      assert entry.socket.assigns.query == "shirt"
    end
  end

  describe "Scenario: Routing to a child of a keyed list" do
    test "dispatches the command to the matching child store handler" do
      pid = start_supervised!({Server, {ProductsListStore, %{}, %{transport_pid: self()}}})

      assert {:ok, %{selected: "prod_123"}} =
               Server.command(pid, ["products", "prod_123"], :select, %{})

      assert {:ok, %{selected: "prod_456"}} =
               Server.command(pid, ["products", "prod_456"], :select, %{})
    end
  end

  describe "Scenario: Path that does not resolve crashes the runtime" do
    test "raises and exits the page runtime when the path is unknown" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})
      Process.link(pid)

      capture_log(fn ->
        catch_exit(Server.command(pid, ["missing"], :select, %{"id" => "x"}))
        assert_receive {:EXIT, ^pid, _reason}
        Logger.flush()
      end)
    end
  end

  describe "Scenario: Command name absent from the addressed store crashes" do
    test "raises and exits when the addressed store does not declare the command" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})
      Process.link(pid)

      capture_log(fn ->
        catch_exit(Server.command(pid, ["filters"], :delete, %{}))
        assert_receive {:EXIT, ^pid, _reason}
        Logger.flush()
      end)
    end
  end

  describe "Scenario: Payload conforms to the declared schema" do
    test "validation succeeds; handler runs" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})

      assert {:ok, %{}} =
               Server.command(pid, ["filters"], :change_query, %{"query" => "shirt"})
    end
  end

  describe "Scenario: Payload violates a declared field type" do
    test "schema validation hook raises before any handler runs" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})
      Process.link(pid)

      capture_log(fn ->
        catch_exit(Server.command(pid, ["filters"], :change_query, %{"query" => 42}))
        assert_receive {:EXIT, ^pid, _reason}
        Logger.flush()
      end)
    end
  end

  describe "Scenario: Authorization hook halts an unauthorized command" do
    test "halt with reply produces channel ok status with the halt payload" do
      pid =
        start_supervised!({Server, {HaltingStore, %{test_pid: self()}, %{transport_pid: self()}}})

      assert {:ok, %{ok: false, reason: "unauthorized"}} =
               Server.command(pid, [], :restricted, %{})

      refute_received :handler_should_not_run
    end
  end

  describe "Scenario: Hook halts without a reply" do
    test "delivers default ok reply with empty payload" do
      pid =
        start_supervised!(
          {Server, {SilentHaltStore, %{test_pid: self()}, %{transport_pid: self()}}}
        )

      assert {:ok, %{}} = Server.command(pid, [], :gated, %{})
      refute_received :handler_should_not_run
    end
  end

  describe "Scenario: Handler chooses {:noreply, socket}" do
    test "client receives a reply with empty payload and state mutates" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})

      assert {:ok, %{}} = Server.command(pid, ["filters"], :wipe, %{})
    end
  end

  describe "Scenario: Handler chooses {:reply, payload, socket}" do
    test "the client receives the handler's reply payload" do
      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})

      assert {:ok, %{selected: "abc"}} =
               Server.command(pid, ["leaf"], :select, %{"id" => "abc"})
    end
  end

  describe "Scenario: A handler crash terminates the page runtime" do
    test "the page runtime exits and the caller observes the exit" do
      pid = start_supervised!({Server, {CrashingStore, %{}, %{transport_pid: self()}}})
      Process.link(pid)

      capture_log(fn ->
        catch_exit(Server.command(pid, [], :boom, %{}))
        assert_receive {:EXIT, ^pid, _reason}
        Logger.flush()
      end)
    end
  end

  describe "Scenario: A root-attached hook runs before a child-attached hook" do
    test "root hook fires before the child hook for a command on the child" do
      params = %{}

      pid = start_supervised!({Server, {RootStore, params, %{transport_pid: self()}}})

      :ok = inject_root_hook_audit(pid, self())

      assert {:ok, _reply} =
               Server.command(pid, ["filters"], :change_query, %{"query" => "x"})

      assert_received {:hook, :root_before, :change_query}
      assert_received {:hook, :root_after, :change_query}
    end
  end

  describe "Scenario: Successful command emits start and stop telemetry" do
    test "emits :start and :stop with metadata page_id, store_id, command, status" do
      handler_id = "command-telemetry-#{System.unique_integer([:positive, :monotonic])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:arbor, :command, :start],
          [:arbor, :command, :stop]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid =
        start_supervised!({Server, {RootStore, %{"page_id" => "home"}, %{transport_pid: self()}}})

      assert {:ok, _reply} = Server.command(pid, ["filters"], :wipe, %{})

      assert_receive {:telemetry, [:arbor, :command, :start], _,
                      %{
                        page_id: "home",
                        store_id: ["filters"],
                        command: :wipe
                      }}

      assert_receive {:telemetry, [:arbor, :command, :stop], _,
                      %{
                        page_id: "home",
                        store_id: ["filters"],
                        command: :wipe,
                        status: :ok
                      }}
    end

    test "stop metadata excludes the payload contents" do
      handler_id = "command-stop-meta-#{System.unique_integer([:positive, :monotonic])}"

      :telemetry.attach(
        handler_id,
        [:arbor, :command, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_supervised!({Server, {RootStore, %{}, %{transport_pid: self()}}})

      assert {:ok, _reply} =
               Server.command(pid, ["filters"], :change_query, %{"query" => "secret-payload"})

      assert_receive {:telemetry, [:arbor, :command, :stop], _, metadata}

      refute Map.has_key?(metadata, :payload)
      refute String.contains?(inspect(metadata), "secret-payload")
    end
  end

  describe "Scenario: Handler crash emits an exception event" do
    test "telemetry exception fires with kind/reason/stacktrace" do
      handler_id = "command-exception-#{System.unique_integer([:positive, :monotonic])}"

      :telemetry.attach(
        handler_id,
        [:arbor, :command, :exception],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_supervised!({Server, {CrashingStore, %{}, %{transport_pid: self()}}})
      Process.link(pid)

      capture_log(fn ->
        catch_exit(Server.command(pid, [], :boom, %{}))
        assert_receive {:EXIT, ^pid, _reason}

        assert_receive {:telemetry, [:arbor, :command, :exception], _,
                        %{kind: :error, reason: %RuntimeError{}, stacktrace: stacktrace}}

        assert is_list(stacktrace)
        Logger.flush()
      end)
    end
  end

  # `RootStore.mount/1` reads `socket.private[:hook_events]` to know whether to
  # attach the audit hooks. We can't pass the test pid through `params`
  # (assigns) because params don't reach private. Inject via :sys for testing.
  defp inject_root_hook_audit(pid, test_pid) do
    :sys.replace_state(pid, fn %State{} = state ->
      next_root_socket =
        state.root_socket
        |> Socket.put_private(:hook_events, test_pid)
        |> Lifecycle.attach_hook(:audit_before, :before_command, fn name, _payload, sock ->
          send(test_pid, {:hook, :root_before, name})
          {:cont, sock}
        end)
        |> Lifecycle.attach_hook(:audit_after, :after_command, fn name, _payload, sock ->
          send(test_pid, {:hook, :root_after, name})
          {:cont, sock}
        end)

      sync_root_into_registry(%{state | root_socket: next_root_socket})
    end)

    :ok
  end

  defp sync_root_into_registry(%State{root_socket: root_socket, store_registry: registry} = state) do
    case StoreRegistry.get(registry, []) do
      nil ->
        state

      entry ->
        next_registry = StoreRegistry.put(registry, [], %{entry | socket: root_socket})
        %{state | store_registry: next_registry}
    end
  end
end
