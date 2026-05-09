defmodule Arbor.Page.ServerTest do
  use ExUnit.Case, async: true

  alias Arbor.Page.Server
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry

  defmodule RootStore do
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
    assert root_socket.assigns == %{}
    assert version == 0
    assert transport == %{transport_pid: self()}

    assert StoreRegistry.keys(store_registry) == [{[], RootStore, ""}]

    assert registry_entry = StoreRegistry.get(store_registry, [], RootStore, "")
    assert registry_entry.module == RootStore
    assert registry_entry.socket == root_socket
    assert StoreRegistry.path_lookup(store_registry, []) == registry_entry

    GenServer.stop(pid)
  end
end
