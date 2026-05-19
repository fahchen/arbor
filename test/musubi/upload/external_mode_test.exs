defmodule Musubi.Upload.ExternalModeTest do
  @moduledoc """
  Covers BDR-0027: when a store implements `upload_external/3`, the
  preflight reply switches to external-mode meta and progress events
  on the main channel drive the same `{op: progress}` / `{op: complete}`
  emissions.
  """

  use ExUnit.Case, async: true

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :musubi
  end

  defmodule S3Store do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png), max_entries: 1)

    @impl Musubi.Store
    def render(_socket), do: %{title: "Hi"}
    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}

    @impl Musubi.Store
    def upload_external(:avatar, entry, socket) do
      meta = %{
        uploader: "S3",
        url: "https://example.com/upload/" <> entry.ref,
        headers: %{"x-foo" => "bar"}
      }

      {:ok, meta, socket}
    end
  end

  setup_all do
    # Keyed by this test module's full `TestEndpoint` alias, so no other
    # test reads or writes the same `:musubi` app env entry. Scoped
    # per-test config rather than shared global state.
    Application.put_env(:musubi, TestEndpoint,
      secret_key_base: String.duplicate("a", 64),
      server: false,
      pubsub_server: __MODULE__.PubSub
    )

    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    start_supervised!(TestEndpoint)
    :ok
  end

  test "preflight returns external entry meta and no token" do
    page = Musubi.Testing.mount(S3Store)
    assert_receive {:patch, _initial}

    entries = [%{"client_ref" => "0", "name" => "me.png", "size" => 100, "type" => "image/png"}]
    {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)

    [{"0", entry}] = Enum.to_list(reply["entries"])
    assert entry["type"] == "external"
    assert entry["uploader"] == "S3"
    assert entry["meta"]["url"] =~ "https://example.com/upload/"
    refute Map.has_key?(entry, "token")
    stop_page(page)
  end

  test "cancel of an in-flight external entry emits {op: cancel} and removes the entry" do
    page = Musubi.Testing.mount(S3Store)
    assert_receive {:patch, _initial}

    {:ok, reply} =
      Musubi.Testing.allow_upload(
        page,
        :avatar,
        [%{"client_ref" => "0", "name" => "a.png", "size" => 100, "type" => "image/png"}],
        endpoint: TestEndpoint
      )

    [{_cref, %{"entry_ref" => entry_ref}}] = Enum.to_list(reply["entries"])
    assert_receive {:patch, _add}

    Musubi.Testing.simulate_external_progress(page, :avatar, entry_ref, 30)
    assert_receive {:patch, _progress}

    :ok = Musubi.Page.Server.cancel_upload(page.pid, [], :avatar, entry_ref)
    assert_receive {:patch, envelope}

    assert Enum.any?(envelope.upload_ops, fn op ->
             op.op == "cancel" and op.ref == entry_ref
           end)

    {:ok, %{socket: socket}} = Musubi.Page.Server.peek(page.pid, [])
    assert Musubi.Upload.fetch_entry(socket, :avatar, entry_ref) == :error
    stop_page(page)
  end

  defmodule S3StoreWithChannelFallback do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png))
    upload(:receipt, accept: ~w(.pdf))

    @impl Musubi.Store
    def render(_socket), do: %{title: "Hi"}

    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}

    @impl Musubi.Store
    def upload_external(:avatar, entry, socket) do
      {:ok, %{uploader: "S3", url: "https://x/" <> entry.ref}, socket}
    end

    # No clause for :receipt → per-name fallback to channel mode.
  end

  test "per-name fallback: an upload without a matching clause stays in channel mode" do
    page = Musubi.Testing.mount(S3StoreWithChannelFallback)
    assert_receive {:patch, _initial}

    {:ok, reply} =
      Musubi.Testing.allow_upload(
        page,
        :receipt,
        [%{"client_ref" => "0", "name" => "x.pdf", "size" => 1, "type" => "application/pdf"}],
        endpoint: TestEndpoint
      )

    [{_cref, entry}] = Enum.to_list(reply["entries"])
    assert entry["type"] == "channel"
    assert is_binary(entry["token"])
    stop_page(page)
  end

  defmodule MutatingExternalStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
      field :last_uploader, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png))

    @impl Musubi.Store
    def render(socket), do: %{title: "Hi", last_uploader: socket.assigns[:last_uploader]}

    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}

    @impl Musubi.Store
    def upload_external(:avatar, _entry, socket) do
      next = assign(socket, :last_uploader, "S3")
      {:ok, %{uploader: "S3", url: "https://x/"}, next}
    end
  end

  test "upload_external/3 socket mutations survive into the page state" do
    page = Musubi.Testing.mount(MutatingExternalStore)
    assert_receive {:patch, _initial}

    {:ok, _reply} =
      Musubi.Testing.allow_upload(
        page,
        :avatar,
        [%{"client_ref" => "0", "name" => "a.png", "size" => 1, "type" => "image/png"}],
        endpoint: TestEndpoint
      )

    {:ok, %{socket: socket}} = Musubi.Page.Server.peek(page.pid, [])
    assert socket.assigns[:last_uploader] == "S3"
    stop_page(page)
  end

  test "simulate_external_progress emits progress + complete ops" do
    page = Musubi.Testing.mount(S3Store)
    assert_receive {:patch, _initial}

    {:ok, reply} =
      Musubi.Testing.allow_upload(
        page,
        :avatar,
        [%{"client_ref" => "0", "name" => "a.png", "size" => 100, "type" => "image/png"}],
        endpoint: TestEndpoint
      )

    [{_cref, %{"entry_ref" => entry_ref}}] = Enum.to_list(reply["entries"])
    assert_receive {:patch, _add}

    Musubi.Testing.simulate_external_progress(page, :avatar, entry_ref, 42)
    assert_receive {:patch, envelope}

    assert Enum.any?(envelope.upload_ops, fn op ->
             op.op == "progress" and op.progress == 42 and op.ref == entry_ref
           end)

    Musubi.Testing.simulate_external_progress(page, :avatar, entry_ref, 100)
    assert_receive {:patch, envelope}

    assert Enum.any?(envelope.upload_ops, fn op -> op.op == "complete" and op.ref == entry_ref end)

    stop_page(page)
  end

  defp stop_page(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end
end
