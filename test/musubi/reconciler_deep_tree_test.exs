defmodule Arbor.ReconcilerDeepTreeTest do
  use ExUnit.Case, async: true

  alias Arbor.Page.StoreTable
  alias Arbor.Page.StoreTable.Entry
  alias Arbor.Resolver
  alias Arbor.Socket

  defmodule DeepLeafStore do
    use Arbor.Store

    attr :seed, String.t(), required: true

    state do
      field :title, String.t()
    end

    @impl Arbor.Store
    def mount(socket) do
      {:ok, Socket.assign(socket, :title, socket.assigns.seed)}
    end

    @impl Arbor.Store
    def render(socket) do
      %{title: socket.assigns.title}
    end

    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule DeepMidStore do
    use Arbor.Store

    state do
      field :title, String.t()
      field :leaf, DeepLeafStore.state()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}

    @impl Arbor.Store
    def render(socket) do
      %{
        title: socket.assigns.title,
        leaf: child(DeepLeafStore, id: "leaf", seed: socket.assigns.title)
      }
    end

    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule DeepRootStore do
    use Arbor.Store

    state do
      field :mid, DeepMidStore.state()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}

    @impl Arbor.Store
    def render(socket) do
      %{mid: child(DeepMidStore, id: "mid", title: socket.assigns.title)}
    end

    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  test "leaf dirty crosses reused intermediate and is reflected in the next render" do
    socket = root_socket(DeepRootStore, %{title: "BEFORE"})
    registry = registry(socket)

    assert {:ok, _root_resolved, root_socket, registry} = Resolver.resolve(socket, registry)
    assert %Entry{} = StoreTable.get(registry, ["mid"])
    assert %Entry{} = StoreTable.get(registry, ["mid", "leaf"])

    assert %Entry{socket: leaf_socket} = leaf_entry = StoreTable.get(registry, ["mid", "leaf"])

    dirty_leaf_socket = Socket.assign(leaf_socket, :title, "AFTER")

    dirty_registry =
      StoreTable.put(registry, ["mid", "leaf"], %{leaf_entry | socket: dirty_leaf_socket})

    assert {:ok, _resolved, _next_root_socket, next_registry} =
             Resolver.resolve(root_socket, dirty_registry)

    assert %Entry{} = StoreTable.get(next_registry, ["mid", "leaf"])

    assert %Entry{wire_state: %{"title" => "AFTER"}} =
             StoreTable.get(next_registry, ["mid", "leaf"])
  end

  test "reused intermediate does not prune its descendants" do
    socket = root_socket(DeepRootStore, %{title: "STABLE"})
    registry = registry(socket)

    assert {:ok, _root_resolved, root_socket, registry} = Resolver.resolve(socket, registry)
    assert %Entry{} = StoreTable.get(registry, ["mid", "leaf"])

    assert {:ok, _resolved, _next_root_socket, next_registry} =
             Resolver.resolve(root_socket, registry)

    assert %Entry{} = StoreTable.get(next_registry, ["mid", "leaf"])
  end

  defp registry(%Socket{} = socket) do
    StoreTable.put(
      StoreTable.new(),
      Socket.store_id(socket),
      %Entry{
        socket: socket,
        module: socket.module
      }
    )
  end

  defp root_socket(module, assigns) when is_atom(module) and is_map(assigns) do
    Socket.assign(
      %Socket{id: "", parent_path: [], module: module, assigns: %{}, private: %{}},
      assigns
    )
  end
end
