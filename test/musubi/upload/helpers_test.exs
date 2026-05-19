defmodule Musubi.Upload.HelpersTest do
  @moduledoc """
  Covers the `Musubi.Store` upload facade helpers: `uploaded_entries/2`,
  `consume_uploaded_entries/3`, and `cancel_upload/3`.
  """

  use ExUnit.Case, async: true

  defmodule TestEndpoint do
    use Phoenix.Endpoint, otp_app: :musubi
  end

  defmodule AvatarStore do
    use Musubi.Store, root: true

    state do
      field :avatar_url, String.t() | nil
    end

    upload :avatar, accept: ~w(.png), max_entries: 3

    command :peek
    command :consume
    command :cancel do
      payload :ref, String.t()
    end

    @impl Musubi.Store
    def render(socket), do: %{avatar_url: socket.assigns[:avatar_url]}

    @impl Musubi.Store
    def handle_command(:peek, _payload, socket) do
      {completed, in_progress} = uploaded_entries(socket, :avatar)
      reply = %{completed: Enum.map(completed, & &1.ref), in_progress: Enum.map(in_progress, & &1.ref)}
      {:reply, reply, socket}
    end

    def handle_command(:consume, _payload, socket) do
      {socket, urls} =
        consume_uploaded_entries(socket, :avatar, fn _meta, entry ->
          {:ok, "/uploads/" <> entry.ref}
        end)

      socket = assign(socket, :avatar_url, List.first(urls))
      {:reply, %{urls: urls}, socket}
    end

    def handle_command(:cancel, %{ref: ref}, socket) do
      socket = cancel_upload(socket, :avatar, ref)
      {:reply, %{}, socket}
    end
  end

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

  test "uploaded_entries returns completed and in-progress lists" do
    page = mount_with_two_completed_entries()

    {:ok, reply} = Musubi.Testing.dispatch_command(page, :peek, %{})

    assert length(reply.completed) == 2
    assert reply.in_progress == []
    stop_page(page)
  end

  test "consume_uploaded_entries returns urls and emits reset op" do
    page = mount_with_two_completed_entries()

    {:ok, reply} = Musubi.Testing.dispatch_command(page, :consume, %{})

    assert length(reply.urls) == 2

    assert_receive {:patch, envelope}
    assert Enum.any?(envelope.upload_ops, fn op -> op.op == "reset" and op.upload == "avatar" end)

    # The state field assigned during consume produces an `ops` diff too.
    assert Enum.any?(envelope.ops, fn op -> op.path == "/avatar_url" end)
    stop_page(page)
  end

  test "consume_uploaded_entries raises outside a command handler" do
    socket = %Musubi.Socket{module: AvatarStore}

    assert_raise ArgumentError, ~r/only be called inside a command handler/, fn ->
      Musubi.Upload.consume_uploaded_entries(socket, :avatar, fn _meta, _entry -> {:ok, 1} end)
    end
  end

  defp mount_with_two_completed_entries do
    page = Musubi.Testing.mount(AvatarStore)
    assert_receive {:patch, _initial}

    entries = [
      %{"client_ref" => "0", "name" => "a.png", "size" => 10, "type" => "image/png"},
      %{"client_ref" => "1", "name" => "b.png", "size" => 10, "type" => "image/png"}
    ]

    {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)
    assert_receive {:patch, _add}

    for {_cref, %{"entry_ref" => ref}} <- reply["entries"] do
      Musubi.Testing.simulate_upload(page, :avatar, ref, 10)
      assert_receive {:patch, _progress}
    end

    page
  end

  defp stop_page(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end
end
