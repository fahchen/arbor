defmodule Arbor.TestingTest do
  use ExUnit.Case, async: true

  defmodule SimpleStore do
    use Arbor.Store, root: true

    state do
      field :count, integer()
      field :winner, :none | :p1 | :p2
    end

    command :bump do
      payload(:by, integer())
      reply(%{ok: boolean()})
    end

    command :declare do
      payload(:winner, String.t())
      reply(%{ok: boolean()})
    end

    @impl Arbor.Store
    def mount(_params, socket) do
      socket =
        socket
        |> Arbor.Socket.assign(:count, 0)
        |> Arbor.Socket.assign(:winner, :none)

      {:ok, socket}
    end

    @impl Arbor.Store
    def render(socket) do
      %{count: socket.assigns.count, winner: socket.assigns.winner}
    end

    @impl Arbor.Store
    def handle_command(:bump, %{"by" => n}, socket) do
      {:reply, %{"ok" => true}, Arbor.Socket.assign(socket, :count, socket.assigns.count + n)}
    end

    def handle_command(:declare, %{"winner" => w}, socket) when w in ["p1", "p2"] do
      {:reply, %{"ok" => true}, Arbor.Socket.assign(socket, :winner, String.to_atom(w))}
    end
  end

  describe "mount/3" do
    test "returns a handle carrying pid + root + transport" do
      page = Arbor.Testing.mount(SimpleStore)

      assert %Arbor.Testing{pid: pid, root: SimpleStore, transport: transport} = page
      assert is_pid(pid)
      assert transport == self()
    end

    test "accepts params" do
      page = Arbor.Testing.mount(SimpleStore, %{"any" => "value"})
      assert is_pid(page.pid)
    end
  end

  describe "render/2" do
    test "returns the wire-shape map with atom values intact" do
      page = Arbor.Testing.mount(SimpleStore)

      assert Arbor.Testing.render(page) == %{count: 0, winner: :none}
    end

    test "reflects state after a command settles" do
      page = Arbor.Testing.mount(SimpleStore)

      {:ok, _} = Arbor.Testing.dispatch_command(page, :bump, %{"by" => 3})
      {:ok, _} = Arbor.Testing.dispatch_command(page, :declare, %{"winner" => "p1"})

      assert Arbor.Testing.render(page) == %{count: 3, winner: :p1}
    end
  end

  describe "assigns/2" do
    test "returns raw socket.assigns" do
      page = Arbor.Testing.mount(SimpleStore)
      {:ok, _} = Arbor.Testing.dispatch_command(page, :bump, %{"by" => 5})

      assigns = Arbor.Testing.assigns(page)
      assert assigns.count == 5
      assert assigns.winner == :none
    end
  end

  describe "dispatch_command/4" do
    test "returns the command reply payload" do
      page = Arbor.Testing.mount(SimpleStore)

      assert {:ok, %{"ok" => true}} =
               Arbor.Testing.dispatch_command(page, :bump, %{"by" => 1})
    end
  end
end
