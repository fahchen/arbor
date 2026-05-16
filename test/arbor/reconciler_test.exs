defmodule Arbor.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Arbor.Reconciler
  alias Arbor.Socket

  describe "init_store/1 — required-field validation" do
    defmodule AllAssignedStore do
      use Arbor.Store

      state do
        field :title, String.t()
      end

      @impl Arbor.Store
      def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :title, "ok")}

      @impl Arbor.Store
      def render(socket), do: %{title: socket.assigns.title}

      @impl Arbor.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end

    defmodule MissingFieldStore do
      use Arbor.Store

      state do
        field :title, String.t()
        field :count, integer()
      end

      @impl Arbor.Store
      def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :title, "ok")}

      @impl Arbor.Store
      def render(_socket), do: %{}

      @impl Arbor.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end

    defmodule NullableMissingStore do
      use Arbor.Store

      state do
        field :winner, :p1 | :p2 | nil
      end

      @impl Arbor.Store
      def mount(socket), do: {:ok, socket}

      @impl Arbor.Store
      def render(_socket), do: %{}

      @impl Arbor.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end

    test "passes when every primitive non-nullable field is assigned" do
      socket = %Socket{module: AllAssignedStore}
      result = Reconciler.init_store(socket)

      assert result.assigns.title == "ok"
    end

    test "raises when a primitive non-nullable field is left unassigned" do
      socket = %Socket{module: MissingFieldStore}

      assert_raise ArgumentError, ~r/required fields: \[:count\]/, fn ->
        Reconciler.init_store(socket)
      end
    end

    test "passes when a missing field is declared nullable" do
      socket = %Socket{module: NullableMissingStore}

      assert %Socket{} = Reconciler.init_store(socket)
    end
  end
end
