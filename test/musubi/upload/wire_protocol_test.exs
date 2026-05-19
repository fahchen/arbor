defmodule Musubi.Upload.WireProtocolTest do
  @moduledoc """
  Covers `spec/domains/uploads/features/wire-protocol.feature`:
  envelope `upload_ops`, op vocabulary, store_id stamping, coalescing,
  throttling, change tracking isolation, and scrubbing of server-private
  fields.
  """

  use ExUnit.Case, async: true

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :musubi
  end

  defmodule AvatarStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png), max_entries: 5, max_file_size: 5_000_000)

    def render(socket), do: %{title: socket.assigns[:title]}
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
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

  describe "envelope shape" do
    test "patch envelope wire form has type/base_version/version/ops/stream_ops/upload_ops" do
      envelope = Musubi.Page.PatchEnvelope.initial(%{"title" => "Inbox"}, [], [])
      wire = Musubi.Page.PatchEnvelope.to_wire(envelope)

      assert wire["type"] == "patch"
      assert wire["base_version"] == 0
      assert wire["version"] == 1
      assert wire["ops"] == [%{op: "replace", path: "", value: %{"title" => "Inbox"}}]
      assert wire["stream_ops"] == []
      assert wire["upload_ops"] == []
    end

    test "initial envelope carries marker injection AND config upload_op" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, envelope}

      [%{op: "replace", path: "", value: wire}] = envelope.ops
      assert %{"__musubi_upload__" => "avatar"} = wire["avatar"]

      configs = Enum.filter(envelope.upload_ops, &(&1.op == "config"))
      assert [%{op: "config", upload: "avatar", store_id: [], config: config}] = configs
      assert config["max_file_size"] == 5_000_000
      assert config["max_entries"] == 5
      assert config["accept"] == [".png"]
      stop_page(page)
    end
  end

  describe "op vocabulary" do
    test "preflight emits add ops for accepted entries" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      entries = [
        %{"client_ref" => "0", "name" => "me.png", "size" => 1234, "type" => "image/png"}
      ]

      {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)

      assert reply["errors"] == []
      assert_receive {:patch, envelope}

      add_ops = Enum.filter(envelope.upload_ops, &(&1.op == "add"))
      assert [%{op: "add", upload: "avatar", store_id: [], ref: ref, entry: entry}] = add_ops
      assert is_binary(ref)
      assert entry["client_name"] == "me.png"
      assert entry["client_size"] == 1234

      # Server-private fields scrubbed
      refute Map.has_key?(entry, "path")
      refute Map.has_key?(entry, "token")
      refute Map.has_key?(entry, "store_pid")
      refute Map.has_key?(entry, "bytes_written")

      stop_page(page)
    end

    test "simulate_upload drives a progress + complete chain" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      {:ok, reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "0", "name" => "a.png", "size" => 1000, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      [{_cref, %{"entry_ref" => entry_ref}}] = Enum.to_list(reply["entries"])

      assert_receive {:patch, _add_envelope}

      Musubi.Testing.simulate_upload(page, :avatar, entry_ref, 1000)
      assert_receive {:patch, envelope}

      ops = envelope.upload_ops
      assert Enum.any?(ops, &(&1.op == "progress"))
      assert Enum.any?(ops, &(&1.op == "complete"))
      stop_page(page)
    end

    test "cancel_upload emits a cancel op" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      {:ok, reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "0", "name" => "a.png", "size" => 100, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      [{_cref, %{"entry_ref" => entry_ref}}] = Enum.to_list(reply["entries"])
      assert_receive {:patch, _add_envelope}

      :ok = Musubi.Page.Server.cancel_upload(page.pid, [], :avatar, entry_ref)
      assert_receive {:patch, envelope}

      assert [%{op: "cancel", upload: "avatar", ref: ^entry_ref, store_id: []}] =
               Enum.filter(envelope.upload_ops, &(&1.op == "cancel"))

      stop_page(page)
    end
  end

  describe "preflight rejection" do
    test "rejects oversize entry with error code too_large" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      entries = [
        %{"client_ref" => "0", "name" => "big.png", "size" => 10_000_000, "type" => "image/png"}
      ]

      {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)

      assert reply["entries"] == %{}
      assert [%{"client_ref" => "0", "error" => %{"code" => "too_large"}}] = reply["errors"]
      stop_page(page)
    end

    test "rejects entry with unaccepted extension" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      entries = [%{"client_ref" => "0", "name" => "me.gif", "size" => 100, "type" => "image/gif"}]
      {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)

      assert reply["entries"] == %{}
      assert [%{"error" => %{"code" => "not_accepted"}}] = reply["errors"]
      stop_page(page)
    end
  end

  describe "change tracking isolation" do
    test "upload ops don't dirty unrelated assigns" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      {:ok, reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "0", "name" => "a.png", "size" => 100, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      [{_cref, %{"entry_ref" => entry_ref}}] = Enum.to_list(reply["entries"])
      assert_receive {:patch, _add_envelope}

      Musubi.Testing.simulate_upload(page, :avatar, entry_ref, 100)
      assert_receive {:patch, envelope}

      # ops touching state path /avatar/entries — none. Upload changes flow
      # through upload_ops only.
      refute Enum.any?(envelope.ops, fn op -> String.contains?(op.path || "", "avatar") end)
    end
  end

  describe "token scrubbing" do
    test "Entry wire form drops path, token, store_pid, bytes_written, external_meta" do
      entry = %Musubi.Upload.Entry{
        ref: "u_x",
        client_name: "a.png",
        client_size: 10,
        path: "/secret/path",
        token: "secret",
        store_pid: self(),
        bytes_written: 5,
        external_meta: %{secret: true},
        preflighted_at: 1_000
      }

      wire = Musubi.Wire.to_wire(entry)

      refute Map.has_key?(wire, "path")
      refute Map.has_key?(wire, "token")
      refute Map.has_key?(wire, "store_pid")
      refute Map.has_key?(wire, "bytes_written")
      refute Map.has_key?(wire, "external_meta")
      refute Map.has_key?(wire, "preflighted_at")
    end
  end

  describe "envelope is emitted when only upload_ops is non-empty" do
    test "upload-only cycle still emits an envelope" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      {:ok, _reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "0", "name" => "a.png", "size" => 100, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      # The preflight add op envelope: ops should be empty (no state change),
      # upload_ops should contain the add.
      assert_receive {:patch, envelope}
      assert envelope.ops == []
      assert envelope.upload_ops != []
      stop_page(page)
    end
  end

  defp stop_page(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end
end
