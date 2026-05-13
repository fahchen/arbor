defmodule Arbor.Transport.SessionChannelTest do
  use ExUnit.Case, async: true

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :arbor

    socket("/arbor", Arbor.Transport.SessionChannelTest.ArborSocket,
      websocket: false,
      longpoll: false
    )
  end

  defmodule ChildStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :label, String.t()
    end

    @impl Arbor.Store
    def init(socket) do
      socket
      |> Arbor.Socket.session()
      |> Map.fetch!("test_pid")
      |> send({:child_init, Arbor.Socket.session(socket), Arbor.Socket.connect_info(socket)})

      {:ok, socket}
    end

    @impl Arbor.Store
    def render(socket), do: %{label: socket.assigns.label}

    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule AlphaRootStore do
    @moduledoc false
    use Arbor.Store, root: true

    attr :room_id, String.t(), required: true

    state do
      field :room_id, String.t()
      field :current_user, String.t()
      field :child, ChildStore.state()
    end

    @impl Arbor.Store
    def mount(params, socket) do
      session = Arbor.Socket.session(socket)
      test_pid = Map.fetch!(session, "test_pid")

      send(test_pid, {:alpha_mount, self(), params, socket.assigns.current_user})

      socket = Arbor.Socket.assign(socket, :room_id, Map.fetch!(params, "room_id"))

      {:ok, socket}
    end

    @impl Arbor.Store
    def init(socket) do
      test_pid = Map.fetch!(Arbor.Socket.session(socket), "test_pid")
      send(test_pid, {:alpha_init, socket.assigns.room_id})
      {:ok, socket}
    end

    @impl Arbor.Store
    def render(socket) do
      %{
        room_id: socket.assigns.room_id,
        current_user: socket.assigns.current_user,
        child: child(ChildStore, id: "child", label: socket.assigns.room_id)
      }
    end

    command :rename do
      payload :room_id, String.t()
    end

    @impl Arbor.Store
    def handle_command(:rename, %{"room_id" => room_id}, socket) do
      {:noreply, Arbor.Socket.assign(socket, :room_id, room_id)}
    end
  end

  defmodule BetaRootStore do
    @moduledoc false
    use Arbor.Store, root: true

    state do
      field :label, String.t()
      field :current_user, String.t()
    end

    @impl Arbor.Store
    def mount(params, socket) do
      test_pid = Map.fetch!(Arbor.Socket.session(socket), "test_pid")
      send(test_pid, {:beta_mount, self(), params, socket.assigns.current_user})
      {:ok, Arbor.Socket.assign(socket, :label, Map.fetch!(params, "label"))}
    end

    @impl Arbor.Store
    def render(socket) do
      %{label: socket.assigns.label, current_user: socket.assigns.current_user}
    end

    command :rename do
      payload :label, String.t()
    end

    @impl Arbor.Store
    def handle_command(:rename, %{"label" => label}, socket) do
      {:noreply, Arbor.Socket.assign(socket, :label, label)}
    end
  end

  defmodule NonRootStore do
    @moduledoc false
    use Arbor.Store

    state do
      field :ok, boolean()
    end

    @impl Arbor.Store
    def render(_socket), do: %{ok: true}

    @impl Arbor.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule AppSession do
    @moduledoc false
    use Arbor.Session,
      roots: [
        alpha: Arbor.Transport.SessionChannelTest.AlphaRootStore,
        beta: Arbor.Transport.SessionChannelTest.BetaRootStore,
        non_root: Arbor.Transport.SessionChannelTest.NonRootStore
      ]

    @impl Arbor.Session
    def join(params, session, socket) do
      test_pid = Map.fetch!(session, "test_pid")
      send(test_pid, {:session_join, params, socket.assigns.current_user})

      socket = Arbor.Socket.assign(socket, :current_user, socket.assigns.current_user)

      {:ok, socket}
    end
  end

  defmodule ArborSocket do
    @moduledoc false
    use Arbor.Transport.Socket, session: Arbor.Transport.SessionChannelTest.AppSession
  end

  import Phoenix.ChannelTest

  @endpoint TestEndpoint

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Arbor.Transport.SessionChannelTest.PubSub})
    start_supervised!(TestEndpoint)
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "session join runs once and shared assigns/session are visible to mounted roots and children" do
    {:ok, _reply, socket} = join_session()

    assert_receive {:session_join, %{"scope" => "main"}, "connect-user"}

    mount_ref =
      push(socket, "mount", %{
        "root" => "alpha",
        "id" => "alpha-1",
        "params" => %{"room_id" => "general"}
      })

    assert_reply(mount_ref, :ok, %{"root_id" => "alpha-1"})
    assert_receive {:alpha_mount, alpha_pid, %{"room_id" => "general"}, "connect-user"}
    assert_receive {:alpha_init, "general"}

    assert_receive {:child_init, %{"test_pid" => _test_pid, "user_id" => "u1"},
                    %{peer_data: %{address: {127, 0, 0, 1}}}}

    assert_push("patch", %{
      "root_id" => "alpha-1",
      "ops" => [
        %{
          op: "replace",
          path: "",
          value: %{
            "room_id" => "general",
            "current_user" => "connect-user",
            "child" => %{"label" => "general"}
          }
        }
      ]
    })

    second_ref =
      push(socket, "mount", %{
        "root" => "beta",
        "id" => "beta-1",
        "params" => %{"label" => "secondary"}
      })

    assert_reply(second_ref, :ok, %{"root_id" => "beta-1"})
    assert_receive {:beta_mount, beta_pid, %{"label" => "secondary"}, "connect-user"}

    assert_push("patch", %{
      "root_id" => "beta-1",
      "ops" => [
        %{
          op: "replace",
          path: "",
          value: %{"label" => "secondary", "current_user" => "connect-user"}
        }
      ]
    })

    assert is_pid(alpha_pid)
    assert is_pid(beta_pid)
    refute_receive {:session_join, _params, _current_user}
  end

  test "command routes through root_id and patches only that root" do
    {:ok, _reply, socket} = join_session()
    assert_receive {:session_join, _params, _current_user}

    mount_ref =
      push(socket, "mount", %{
        "root" => "alpha",
        "id" => "alpha-1",
        "params" => %{"room_id" => "general"}
      })

    assert_reply(mount_ref, :ok, %{"root_id" => "alpha-1"})
    assert_receive {:alpha_mount, _pid, _params, _current_user}
    assert_receive {:alpha_init, "general"}
    assert_receive {:child_init, _session, _connect_info}
    assert_push("patch", %{"root_id" => "alpha-1", "version" => 1})

    command_ref =
      push(socket, "command", %{
        "root_id" => "alpha-1",
        "store_id" => [],
        "name" => "rename",
        "payload" => %{"room_id" => "random"}
      })

    assert_reply(command_ref, :ok, %{})

    assert_push("patch", %{
      "root_id" => "alpha-1",
      "version" => 2,
      "ops" => ops
    })

    assert %{op: "replace", path: "/child/label", value: "random"} in ops
    assert %{op: "replace", path: "/room_id", value: "random"} in ops
  end

  test "mount rejects undeclared roots and declared non-root stores" do
    {:ok, _reply, socket} = join_session()
    assert_receive {:session_join, _params, _current_user}

    unknown_ref = push(socket, "mount", %{"root" => "unknown", "params" => %{}})
    assert_reply(unknown_ref, :error, %{reason: "unknown root"})

    non_root_ref = push(socket, "mount", %{"root" => "non_root", "params" => %{}})
    assert_reply(non_root_ref, :error, %{reason: "declared store is not a root store"})
  end

  test "unmount stops only the addressed root store" do
    {:ok, _reply, socket} = join_session()
    assert_receive {:session_join, _params, _current_user}

    alpha_ref =
      push(socket, "mount", %{
        "root" => "alpha",
        "id" => "alpha-1",
        "params" => %{"room_id" => "general"}
      })

    assert_reply(alpha_ref, :ok, %{"root_id" => "alpha-1"})
    assert_receive {:alpha_mount, alpha_pid, _params, _current_user}
    assert_receive {:alpha_init, "general"}
    assert_receive {:child_init, _session, _connect_info}
    assert_push("patch", %{"root_id" => "alpha-1"})

    beta_ref =
      push(socket, "mount", %{
        "root" => "beta",
        "id" => "beta-1",
        "params" => %{"label" => "secondary"}
      })

    assert_reply(beta_ref, :ok, %{"root_id" => "beta-1"})
    assert_receive {:beta_mount, beta_pid, _params, _current_user}
    assert_push("patch", %{"root_id" => "beta-1"})

    alpha_down = Process.monitor(alpha_pid)
    beta_down = Process.monitor(beta_pid)

    unmount_ref = push(socket, "unmount", %{"root_id" => "alpha-1"})
    assert_reply(unmount_ref, :ok, %{})
    assert_receive {:DOWN, ^alpha_down, :process, ^alpha_pid, {:shutdown, :unmounted}}
    refute_receive {:DOWN, ^beta_down, :process, ^beta_pid, _reason}

    command_ref =
      push(socket, "command", %{
        "root_id" => "beta-1",
        "store_id" => [],
        "name" => "rename",
        "payload" => %{"label" => "still-mounted"}
      })

    assert_reply(command_ref, :ok, %{})
    assert_push("patch", %{"root_id" => "beta-1", "ops" => [%{path: "/label"}]})
  end

  defp join_session do
    session = %{"test_pid" => self(), "user_id" => "u1"}
    connect_info = %{session: session, peer_data: %{address: {127, 0, 0, 1}}}

    ArborSocket
    |> socket("user_id", %{current_user: "connect-user"})
    |> Arbor.Transport.Socket.assign_connect_context(%{}, connect_info)
    |> subscribe_and_join(Arbor.Transport.SessionChannel, "arbor:session", %{"scope" => "main"})
  end
end
