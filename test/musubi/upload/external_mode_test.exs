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

    upload :avatar, accept: ~w(.png), max_entries: 1

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
