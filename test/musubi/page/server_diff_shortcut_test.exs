defmodule Musubi.Page.ServerDiffShortcutTest do
  use ExUnit.Case, async: true

  alias Musubi.Page.PatchEnvelope
  alias Musubi.Page.Server
  alias Musubi.Page.Server.State

  defmodule NoopStore do
    @moduledoc false

    use Musubi.Store

    state do
      field :ok, boolean()
    end

    command :ping

    @impl Musubi.Store
    def mount(socket), do: {:ok, Musubi.Socket.assign(socket, :ok, true)}

    @impl Musubi.Store
    def render(socket), do: %{ok: socket.assigns.ok}

    @impl Musubi.Store
    def handle_command(:ping, _payload, socket), do: {:noreply, socket}
  end

  setup do
    handler_id = "diff-shortcut-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:musubi, :diff, :stop],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {{event, measurements, metadata}, self()})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "no-op render cycle skips diff telemetry when the wire root is unchanged" do
    pid = start_supervised!({Server, {NoopStore, %{}, %{transport_pid: self()}}})
    assert_receive {:patch, %PatchEnvelope{base_version: 0, version: 1}}

    assert {:ok, %{}} = Server.command(pid, [], :ping, %{})
    assert %State{version: 1, previous_wire_root: %{"ok" => true}} = :sys.get_state(pid)
    refute_receive {{[:musubi, :diff, :stop], _measurements, _metadata}, ^pid}, 100
    refute_receive {:patch, _envelope}, 100
  end
end
