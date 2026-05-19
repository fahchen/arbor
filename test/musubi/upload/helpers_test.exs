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

    upload(:avatar, accept: ~w(.png), max_entries: 3)

    command :peek
    command :consume

    command :cancel do
      payload do
        field :ref, String.t()
      end
    end

    @impl Musubi.Store
    def render(socket), do: %{avatar_url: socket.assigns[:avatar_url]}

    @impl Musubi.Store
    def handle_command(:peek, _payload, socket) do
      {completed, in_progress} = uploaded_entries(socket, :avatar)

      reply = %{
        completed: Enum.map(completed, & &1.ref),
        in_progress: Enum.map(in_progress, & &1.ref)
      }

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

  defmodule PostponeStore do
    use Musubi.Store, root: true

    state do
      field :avatar_url, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png), max_entries: 1)

    command :postpone_consume
    command :real_consume

    @impl Musubi.Store
    def render(socket), do: %{avatar_url: socket.assigns[:avatar_url]}

    @impl Musubi.Store
    def handle_command(:postpone_consume, _payload, socket) do
      {socket, _vals} =
        consume_uploaded_entries(socket, :avatar, fn _meta, _entry -> {:postpone, :later} end)

      {:reply, %{}, socket}
    end

    def handle_command(:real_consume, _payload, socket) do
      {socket, urls} =
        consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
          true = File.exists?(path)
          {:ok, "/uploaded/" <> Path.basename(path)}
        end)

      {:reply, %{urls: urls}, socket}
    end
  end

  setup_all do
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

  test "consume_uploaded_entries hands the callback a real readable %{path: path}" do
    page = Musubi.Testing.mount(AvatarStore)
    assert_receive {:patch, _initial}, 500

    entries = [%{"client_ref" => "0", "name" => "a.png", "size" => 10, "type" => "image/png"}]
    {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)
    [{_cref, %{"entry_ref" => ref}}] = Enum.to_list(reply["entries"])
    assert_receive {:patch, _add}, 500

    # Pretend the sub-channel ran: register a temp path and mark the
    # entry success. Use a real on-disk file so the assertion is honest.
    path = Path.join(System.tmp_dir!(), "musubi-test-#{ref}")
    File.write!(path, "hello")
    :ok = Musubi.Page.Server.register_upload_channel(page.pid, [], :avatar, ref, self(), path)
    Musubi.Testing.simulate_upload(page, :avatar, ref, 10)
    assert_receive {:patch, _progress}, 500

    {:ok, reply} = Musubi.Testing.dispatch_command(page, :consume, %{})

    refute File.exists?(path), "consume should remove the temp file"
    assert length(reply.urls) == 1
    stop_page(page)
  end

  test "consume_uploaded_entries postpone retains the temp file" do
    page = Musubi.Testing.mount(PostponeStore)
    assert_receive {:patch, _initial}, 500

    entries = [%{"client_ref" => "0", "name" => "a.png", "size" => 5, "type" => "image/png"}]
    {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)
    [{_cref, %{"entry_ref" => ref}}] = Enum.to_list(reply["entries"])
    assert_receive {:patch, _add}, 500

    path = Path.join(System.tmp_dir!(), "musubi-postpone-#{ref}")
    File.write!(path, "data")
    :ok = Musubi.Page.Server.register_upload_channel(page.pid, [], :avatar, ref, self(), path)
    Musubi.Testing.simulate_upload(page, :avatar, ref, 5)
    assert_receive {:patch, _progress}, 500

    {:ok, _reply} = Musubi.Testing.dispatch_command(page, :postpone_consume, %{})

    assert File.exists?(path), "postpone must leave the temp file in place"

    # Second consume sees the same file.
    {:ok, _reply} = Musubi.Testing.dispatch_command(page, :real_consume, %{})

    refute File.exists?(path), "second consume should remove the temp file"
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
