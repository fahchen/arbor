defmodule Arbor.Transport.ChannelTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Arbor.Page.PatchEnvelope

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :arbor

    socket("/socket", Arbor.Transport.ChannelTest.UserSocket,
      websocket: false,
      longpoll: false
    )
  end

  defmodule UserSocket do
    @moduledoc false
    use Phoenix.Socket

    channel("arbor:*", Arbor.Transport.ChannelTest.ArborChannel)

    def connect(_params, socket, _connect_info), do: {:ok, socket}
    def id(_socket), do: nil
  end

  defmodule RootStore do
    @moduledoc false

    use Arbor.Store, root: true

    state do
      field :title, String.t()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :title, "Inbox")}
    @impl Arbor.Store
    def render(socket), do: %{title: socket.assigns.title}

    command :rename do
      payload :title, String.t()
    end

    @impl Arbor.Store
    def handle_command(:rename, %{"title" => title}, socket),
      do: {:noreply, Arbor.Socket.assign(socket, :title, title)}
  end

  defmodule ParamStore do
    @moduledoc false

    use Arbor.Store, root: true

    attr :room_id, String.t(), required: true

    state do
      field :room_id, String.t()
    end

    @impl Arbor.Store
    def mount(socket), do: {:ok, socket}
    @impl Arbor.Store
    def render(socket), do: %{room_id: socket.assigns.room_id}
    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule ArborChannel do
    @moduledoc false

    use Arbor.Transport.Channel,
      stores: [
        Arbor.Transport.ChannelTest.RootStore,
        Arbor.Transport.ChannelTest.ParamStore
      ]
  end

  import Phoenix.ChannelTest
  @endpoint TestEndpoint

  @root_module_str "Arbor.Transport.ChannelTest.RootStore"
  @root_id "home"
  @param_module_str "Arbor.Transport.ChannelTest.ParamStore"

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Arbor.Transport.ChannelTest.PubSub})
    start_supervised!(TestEndpoint)
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp shutdown_channel(%Phoenix.Socket{channel_pid: channel_pid}) do
    ref = Process.monitor(channel_pid)

    capture_log(fn ->
      Process.exit(channel_pid, :shutdown)

      receive do
        {:DOWN, ^ref, _type, _pid, _reason} -> :ok
      after
        1_000 -> :ok
      end

      Logger.flush()
    end)
  end

  defp join_root(payload \\ %{}) do
    full_payload =
      Map.merge(
        %{"module" => @root_module_str, "id" => @root_id, "params" => %{}},
        payload
      )

    UserSocket
    |> socket("user_id", %{})
    |> subscribe_and_join(ArborChannel, "arbor:#{@root_id}", full_payload)
  end

  test "join starts a page server and pushes the initial patch envelope" do
    {:ok, _reply, socket} = join_root()

    assert_push("patch", %{
      "type" => "patch",
      "base_version" => 0,
      "version" => 1,
      "ops" => [%{op: "replace", path: "", value: %{"title" => "Inbox"}}],
      "stream_ops" => []
    })

    shutdown_channel(socket)
  end

  test "join does not normalize string-keyed params for root store attrs" do
    log =
      capture_log(fn ->
        assert {:error, %{reason: "join crashed"}} =
                 join_root(%{
                   "module" => @param_module_str,
                   "params" => %{"room_id" => "general"}
                 })
      end)

    assert log =~ "missing required attr :room_id"
  end

  test "command event flows through Arbor.Page.Server.command/4 and replies + patches" do
    {:ok, _reply, socket} = join_root()

    assert_push("patch", %{"version" => 1})

    ref =
      push(socket, "command", %{
        "store_id" => [],
        "name" => "rename",
        "payload" => %{"title" => "Outbox"}
      })

    assert_reply(ref, :ok, %{})

    assert_push("patch", %{
      "version" => 2,
      "base_version" => 1,
      "ops" => [%{op: "replace", path: "/title", value: "Outbox"}]
    })

    shutdown_channel(socket)
  end

  test "join + leave emit channel telemetry and stop the linked page server" do
    handler = self()

    :telemetry.attach_many(
      "arbor-channel-test",
      [
        [:arbor, :channel, :join],
        [:arbor, :channel, :terminate]
      ],
      fn name, _meas, meta, _config -> send(handler, {:channel_event, name, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("arbor-channel-test") end)

    {:ok, _reply, channel_socket} = join_root()

    assert_receive {:channel_event, [:arbor, :channel, :join],
                    %{module: RootStore, id: @root_id, page_pid: page_pid}}

    assert is_pid(page_pid)
    assert Process.alive?(page_pid)
    page_ref = Process.monitor(page_pid)

    Process.flag(:trap_exit, true)
    leave_ref = Phoenix.ChannelTest.leave(channel_socket)
    assert_reply(leave_ref, :ok)

    assert_receive {:channel_event, [:arbor, :channel, :terminate],
                    %{module: RootStore, id: @root_id}}

    assert_receive {:DOWN, ^page_ref, :process, ^page_pid, _reason}, 1_000
  end

  test "join rejects a module not in the allowlist" do
    assert {:error, %{reason: reason}} =
             UserSocket
             |> socket("user_id", %{})
             |> subscribe_and_join(ArborChannel, "arbor:home", %{
               "module" => "MyApp.Unknown",
               "id" => @root_id,
               "params" => %{}
             })

    assert reason =~ "not in the channel allowlist"
  end

  test "to_wire/1 returns string-keyed envelope ready for Phoenix.Channel.push/3" do
    envelope = %PatchEnvelope{
      type: "patch",
      base_version: 4,
      version: 5,
      ops: [%{op: "remove", path: "/x"}],
      stream_ops: []
    }

    assert PatchEnvelope.to_wire(envelope) == %{
             "type" => "patch",
             "base_version" => 4,
             "version" => 5,
             "ops" => [%{op: "remove", path: "/x"}],
             "stream_ops" => []
           }
  end
end
