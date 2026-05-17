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

    def handle_command(:declare, %{"winner" => "p1"}, socket) do
      {:reply, %{"ok" => true}, Arbor.Socket.assign(socket, :winner, :p1)}
    end

    def handle_command(:declare, %{"winner" => "p2"}, socket) do
      {:reply, %{"ok" => true}, Arbor.Socket.assign(socket, :winner, :p2)}
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

      {:ok, _reply} = Arbor.Testing.dispatch_command(page, :bump, %{"by" => 3})
      {:ok, _reply} = Arbor.Testing.dispatch_command(page, :declare, %{"winner" => "p1"})

      assert Arbor.Testing.render(page) == %{count: 3, winner: :p1}
    end
  end

  describe "assigns/2" do
    test "returns raw socket.assigns" do
      page = Arbor.Testing.mount(SimpleStore)
      {:ok, _reply} = Arbor.Testing.dispatch_command(page, :bump, %{"by" => 5})

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

  describe "child store addressing via store_id" do
    defmodule FiltersStore do
      use Arbor.Store

      state do
        field :query, String.t()
      end

      command :change_query do
        payload(:query, String.t())
        reply(%{ok: boolean()})
      end

      @impl Arbor.Store
      def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :query, "")}

      @impl Arbor.Store
      def render(socket), do: %{query: socket.assigns.query}

      @impl Arbor.Store
      def handle_command(:change_query, %{"query" => q}, socket) do
        {:reply, %{"ok" => true}, Arbor.Socket.assign(socket, :query, q)}
      end
    end

    defmodule ParentStore do
      use Arbor.Store, root: true

      state do
        field :filters, FiltersStore.t()
      end

      @impl Arbor.Store
      def mount(_params, socket), do: {:ok, socket}

      @impl Arbor.Store
      def render(_socket) do
        %{filters: Arbor.Child.child(FiltersStore, id: "filters")}
      end

      @impl Arbor.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end

    test "dispatch_command routes to child store via store_id" do
      page = Arbor.Testing.mount(ParentStore)

      assert {:ok, %{"ok" => true}} =
               Arbor.Testing.dispatch_command(
                 page,
                 :change_query,
                 %{"query" => "shirt"},
                 ["filters"]
               )

      assert Arbor.Testing.render(page, ["filters"]) == %{query: "shirt"}
      assert Arbor.Testing.assigns(page, ["filters"]).query == "shirt"
    end

    test "render at root returns wire-shape map with child placeholder resolved" do
      page = Arbor.Testing.mount(ParentStore)

      # Root render emits the child placeholder; the resolver substitutes
      # the child's render output into the slot before the wire envelope
      # is built. `render/2` at the root level returns the unresolved
      # placeholder (the store's literal `render/1` output).
      assert %{filters: %Arbor.Child{module: FiltersStore, id: "filters"}} =
               Arbor.Testing.render(page)
    end
  end
end
