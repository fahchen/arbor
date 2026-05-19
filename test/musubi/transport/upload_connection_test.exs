defmodule Musubi.Transport.UploadConnectionTest do
  @moduledoc """
  Drives `allow_upload` / `cancel_upload` / `upload_progress` through
  the real `Musubi.Transport.ConnectionChannel` against a tree where
  the upload lives on a child store. Exercises Codex blocker 1
  (resolve upload via `store_id`, not root).
  """

  use ExUnit.Case

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :musubi

    socket("/musubi", Musubi.Transport.UploadConnectionTest.MusubiSocket,
      websocket: false,
      longpoll: false
    )
  end

  defmodule CartLineStore do
    @moduledoc false
    use Musubi.Store

    attr :line_id, String.t(), required: true

    state do
      field :line_id, String.t()
    end

    upload(:attachment, accept: ~w(.pdf), max_entries: 1, max_file_size: 1_000)

    @impl Musubi.Store
    def init(socket) do
      {:ok, Musubi.Socket.assign(socket, :line_id, socket.assigns.line_id)}
    end

    @impl Musubi.Store
    def render(socket), do: %{line_id: socket.assigns.line_id}

    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}
  end

  defmodule CartStore do
    @moduledoc false
    use Musubi.Store, root: true

    state do
      field :lines, list(CartLineStore.state())
    end

    @impl Musubi.Store
    def mount(_params, socket) do
      {:ok, Musubi.Socket.assign(socket, :lines, ["1", "2"])}
    end

    @impl Musubi.Store
    def render(socket) do
      lines =
        Enum.map(socket.assigns.lines, fn id ->
          Musubi.Child.child(CartLineStore, id: "line-#{id}", line_id: id)
        end)

      %{lines: lines}
    end

    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}
  end

  defmodule MusubiSocket do
    @moduledoc false
    use Musubi.Socket, roots: [Musubi.Transport.UploadConnectionTest.CartStore]
  end

  import Phoenix.ChannelTest

  @endpoint TestEndpoint

  setup_all do
    Application.put_env(:musubi, TestEndpoint,
      secret_key_base: String.duplicate("a", 64),
      server: false,
      pubsub_server: __MODULE__.PubSub
    )

    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    start_supervised!(TestEndpoint)
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    {:ok, _r, socket} = join_connection()

    mount_ref =
      push(socket, "mount", %{
        "module" => "Musubi.Transport.UploadConnectionTest.CartStore",
        "id" => "cart-1",
        "params" => %{}
      })

    assert_reply(mount_ref, :ok, _)

    {:ok, socket: socket}
  end

  test "allow_upload on a child store_id resolves the child upload", %{socket: socket} do
    push_ref =
      push(socket, "allow_upload", %{
        "root_id" => "cart-1",
        "store_id" => ["lines", "line-2"],
        "name" => "attachment",
        "entries" => [
          %{"client_ref" => "0", "name" => "spec.pdf", "size" => 100, "type" => "application/pdf"}
        ]
      })

    assert_reply(push_ref, :ok, reply)
    assert reply["ref"] == "attachment"
    assert reply["errors"] == []
    [{"0", entry}] = Enum.to_list(reply["entries"])
    assert entry["type"] == "channel"
    assert is_binary(entry["token"])
  end

  test "allow_upload on the root rejects when the upload is not declared there", %{socket: socket} do
    push_ref =
      push(socket, "allow_upload", %{
        "root_id" => "cart-1",
        "store_id" => [],
        "name" => "attachment",
        "entries" => [
          %{"client_ref" => "0", "name" => "spec.pdf", "size" => 1, "type" => "application/pdf"}
        ]
      })

    assert_reply(push_ref, :error, %{reason: reason})
    assert reason =~ "unknown"
  end

  test "cancel_upload routes by child store_id", %{socket: socket} do
    push_ref =
      push(socket, "allow_upload", %{
        "root_id" => "cart-1",
        "store_id" => ["lines", "line-1"],
        "name" => "attachment",
        "entries" => [
          %{"client_ref" => "0", "name" => "a.pdf", "size" => 1, "type" => "application/pdf"}
        ]
      })

    assert_reply(push_ref, :ok, reply)
    [{_, %{"entry_ref" => entry_ref}}] = Enum.to_list(reply["entries"])

    push_ref =
      push(socket, "cancel_upload", %{
        "root_id" => "cart-1",
        "store_id" => ["lines", "line-1"],
        "name" => "attachment",
        "ref" => entry_ref
      })

    assert_reply(push_ref, :ok, _)
  end

  defp join_connection do
    session = %{"test_pid" => self()}
    connect_info = %{session: session}
    phoenix_socket = socket(MusubiSocket, "x", %{})

    {:ok, connected_socket} = MusubiSocket.connect(%{}, phoenix_socket, connect_info)

    subscribe_and_join(
      connected_socket,
      Musubi.Transport.ConnectionChannel,
      "musubi:connection",
      %{}
    )
  end
end
