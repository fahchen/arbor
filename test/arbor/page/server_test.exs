defmodule Arbor.Page.ServerTest do
  use ExUnit.Case, async: true

  alias Arbor.Page.Server
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defmodule RootStore do
    use Arbor.Store

    state do
      field :status, String.t()
    end

    def mount(socket) do
      {:ok, Arbor.Socket.assign(socket, :status, "mounted")}
    end

    def to_state(socket) do
      %{status: socket.assigns.status}
    end
  end

  defmodule TerminatesRootStore do
    use Arbor.Store

    state do
      field :status, String.t()
    end

    def mount(socket) do
      {:ok, Arbor.Socket.assign(socket, status: "mounted")}
    end

    def to_state(socket) do
      %{status: socket.assigns.status}
    end

    def terminate(reason, socket) do
      send(socket.assigns.test_pid, {:root_terminate, reason, socket.assigns.status})
      :ok
    end
  end

  test "page server init builds a root socket and inserts it into the registry" do
    assert {:ok, pid} = Server.start_link({RootStore, %{}, %{transport_pid: self()}})
    assert %State{} = :sys.get_state(pid)

    %State{
      root_module: RootStore,
      root_socket: root_socket,
      store_registry: store_registry,
      version: version,
      transport: transport
    } = :sys.get_state(pid)

    assert root_socket.id == ""
    assert root_socket.parent_path == []
    assert root_socket.module == RootStore
    assert root_socket.assigns == %{__changed__: %{}, status: "mounted"}

    assert %{before_command: [%{id: Arbor.Hooks.ValidateCommandSchema}]} =
             Arbor.Socket.get_private(root_socket, :hooks)

    # M4: initial render emits the bootstrap envelope (version 1).
    assert version == 1
    assert transport == %{transport_pid: self()}

    assert_receive {:patch, %Arbor.Page.PatchEnvelope{base_version: 0, version: 1}}

    assert StoreRegistry.keys(store_registry) == [{[], RootStore, ""}]

    assert registry_entry = StoreRegistry.get(store_registry, [], RootStore, "")
    assert registry_entry.module == RootStore
    assert registry_entry.socket == root_socket
    assert registry_entry.resolved_state == %{status: "mounted"}
    assert registry_entry.wire_state == %{"status" => "mounted"}
    assert StoreRegistry.path_lookup(store_registry, []) == registry_entry

    GenServer.stop(pid)
  end

  test "default hooks include ValidateCommandSchema everywhere and ValidateToState in dev" do
    default_hooks = Application.get_env(:arbor, :default_hooks, [])

    assert Enum.any?(default_hooks, fn
             {Arbor.Hooks.ValidateCommandSchema, :before_command, _fun} -> true
             _other -> false
           end)

    if Mix.env() == :dev do
      assert Enum.any?(default_hooks, fn
               {Arbor.Hooks.ValidateToState, :after_serialize, _fun} -> true
               _other -> false
             end)
    else
      refute Enum.any?(default_hooks, fn
               {Arbor.Hooks.ValidateToState, :after_serialize, _fun} -> true
               _other -> false
             end)
    end
  end

  test "root terminate fires on runtime exit" do
    assert {:ok, pid} =
             Server.start_link(
               {TerminatesRootStore, %{test_pid: self()}, %{transport_pid: self()}}
             )

    GenServer.stop(pid, :shutdown)

    assert_receive {:root_terminate, :shutdown, "mounted"}
  end

  defmodule HandleInfoStore do
    use Arbor.Store

    state do
      field :counter, integer()
    end

    def mount(socket) do
      {:ok, Arbor.Socket.assign(socket, :counter, 0)}
    end

    def handle_info(:bump, socket) do
      {:noreply, Arbor.Socket.update_assign(socket, :counter, &(&1 + 1))}
    end

    def to_state(socket) do
      %{counter: socket.assigns.counter}
    end
  end

  test "catch-all handle_info dispatches to root store and emits [:arbor, :pubsub, :receive]" do
    handler = self()

    :telemetry.attach(
      "pubsub-receive-test",
      [:arbor, :pubsub, :receive],
      fn _name, _meas, meta, _config -> send(handler, {:pubsub_receive, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pubsub-receive-test") end)

    assert {:ok, pid} =
             Server.start_link({HandleInfoStore, %{}, %{transport_pid: self()}})

    # consume initial bootstrap envelope
    assert_receive {:patch, _envelope}

    send(pid, :bump)

    assert_receive {:pubsub_receive, %{module: HandleInfoStore}}
    assert_receive {:patch, %{ops: ops}}
    assert Enum.any?(ops, fn op -> op[:path] == "/counter" and op[:value] == 1 end)
  end

  defmodule DenyStore do
    use Arbor.Store

    state do
      field :status, String.t()
    end

    command(:do_thing)

    def mount(socket) do
      socket = Arbor.Socket.assign(socket, :status, "ready")

      socket =
        Arbor.Lifecycle.attach_hook(socket, :authz, :before_command, fn _name, _payload, s ->
          {:halt, %{"error" => "forbidden"}, s}
        end)

      {:ok, socket}
    end

    def handle_command(:do_thing, _payload, socket) do
      {:noreply, socket}
    end

    def to_state(socket) do
      %{status: socket.assigns.status}
    end
  end

  test "graceful denial via :before_command halt-with-reply emits [:arbor, :auth, :deny]" do
    handler = self()

    :telemetry.attach(
      "auth-deny-test",
      [:arbor, :auth, :deny],
      fn _name, _meas, meta, _config -> send(handler, {:auth_deny, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("auth-deny-test") end)

    assert {:ok, pid} = Server.start_link({DenyStore, %{}, %{transport_pid: self()}})
    assert_receive {:patch, _envelope}

    assert {:ok, %{"error" => "forbidden"}} = Server.command(pid, [], :do_thing, %{})

    assert_receive {:auth_deny, %{command: :do_thing, module: DenyStore, path: []}}
  end
end
