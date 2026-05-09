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

    assert version == 0
    assert transport == %{transport_pid: self()}

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
end
