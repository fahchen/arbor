defmodule Musubi.ReconcilerFalsePositiveTest do
  use ExUnit.Case, async: true

  alias Musubi.Page.StoreTable
  alias Musubi.Page.StoreTable.Entry
  alias Musubi.Resolver
  alias Musubi.Socket

  defmodule ChildStore do
    use Musubi.Store

    attr :title, String.t(), required: true
    attr :test_pid, pid(), required: true

    state do
      field :title, String.t()
    end

    @impl Musubi.Store
    def mount(socket), do: {:ok, socket}

    @impl Musubi.Store
    def update(assigns, socket) do
      send(socket.assigns.test_pid, :child_update)
      {:ok, Socket.assign(socket, assigns)}
    end

    @impl Musubi.Store
    def render(socket) do
      send(socket.assigns.test_pid, :child_render)
      %{title: socket.assigns.title}
    end

    @impl Musubi.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule ParentStore do
    use Musubi.Store

    state do
      field :child, ChildStore.state()
    end

    @impl Musubi.Store
    def mount(socket), do: {:ok, socket}

    @impl Musubi.Store
    def render(socket) do
      %{
        child: child(ChildStore, id: "c", title: "static", test_pid: socket.assigns.test_pid)
      }
    end

    @impl Musubi.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  test "child reuses when parent dirty key has the same existing child assign value" do
    socket = root_socket(ParentStore, %{title: "Inbox", test_pid: self()})
    registry = registry(socket)

    assert {:ok, _resolved_root, root_socket, registry} = Resolver.resolve(socket, registry)
    assert_receive :child_render

    next_socket = Socket.assign(root_socket, :title, "Outbox")

    assert {:ok, _resolved_root, _next_root_socket, _registry} =
             Resolver.resolve(next_socket, registry)

    refute_receive :child_update, 50
    refute_receive :child_render, 50
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
