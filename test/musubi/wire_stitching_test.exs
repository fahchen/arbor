defmodule Musubi.WireStitchingTest do
  use ExUnit.Case, async: true

  alias Musubi.Page.StoreTable
  alias Musubi.Page.StoreTable.Entry
  alias Musubi.Resolver
  alias Musubi.Socket

  defmodule ChildStore do
    use Musubi.Store

    state do
      field :val, integer()
    end

    @impl Musubi.Store
    def mount(socket), do: {:ok, socket}

    @impl Musubi.Store
    def render(socket) do
      %{val: socket.assigns.val}
    end

    @impl Musubi.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule RootStore do
    use Musubi.Store

    state do
      field :title, String.t()
      field :child, ChildStore.state()
    end

    @impl Musubi.Store
    def mount(socket), do: {:ok, socket}

    @impl Musubi.Store
    def render(socket) do
      %{
        title: socket.assigns.title,
        child: child(ChildStore, id: "c", val: socket.assigns.val)
      }
    end

    @impl Musubi.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  test "reused child wire subtree reuses the cached child wire_state term" do
    socket = root_socket(RootStore, %{title: "T", val: 1})

    assert {:ok, _resolved_root, socket, registry} = Resolver.resolve(socket, registry(socket))

    assert %Entry{wire_state: child_wire_before} = StoreTable.get(registry, ["c"])

    assert {:ok, _resolved_root, _socket, next_registry} = Resolver.resolve(socket, registry)
    assert %Entry{wire_state: root_wire} = StoreTable.get(next_registry, [])
    assert %{"child" => child_wire_after} = root_wire

    assert true = :erts_debug.same(child_wire_after, child_wire_before)
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
