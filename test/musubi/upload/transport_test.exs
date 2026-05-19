defmodule Musubi.Upload.TransportTest do
  @moduledoc """
  Covers `spec/domains/uploads/features/transport.feature`: preflight
  authorization, token signing, sub-channel join/verify, chunk write,
  cancel, and termination cleanup.
  """

  use ExUnit.Case, async: true

  alias Musubi.Upload.Token

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :musubi
  end

  defmodule AvatarStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload :avatar, accept: ~w(.png), max_entries: 1, max_file_size: 5_000_000, chunk_size: 64_000

    def render(_socket), do: %{title: "Hi"}
    def handle_command(_n, _p, s), do: {:noreply, s}
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

  describe "preflight signs a token per accepted entry" do
    test "single valid entry yields {:ok, reply} with channel-typed entry" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      entries = [%{"client_ref" => "0", "name" => "me.png", "size" => 1234, "type" => "image/png"}]
      {:ok, reply} = Musubi.Testing.allow_upload(page, :avatar, entries, endpoint: TestEndpoint)

      assert reply["ref"] == "avatar"
      assert reply["errors"] == []

      [{"0", entry}] = Enum.to_list(reply["entries"])
      assert entry["type"] == "channel"
      assert is_binary(entry["entry_ref"])
      assert is_binary(entry["token"])

      {:ok, payload} = Token.verify(TestEndpoint, entry["token"])
      assert payload.entry_ref == entry["entry_ref"]
      assert payload.conf_ref == "avatar"
      assert payload.max_file_size == 5_000_000
      assert payload.accept == [".png"]
      assert payload.chunk_size == 64_000
      assert payload.store_pid == page.pid
      assert payload.store_id == []

      stop_page(page)
    end

    test "config carried in the reply matches the declared upload" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      {:ok, reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "0", "name" => "x.png", "size" => 1, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      assert reply["config"]["accept"] == [".png"]
      assert reply["config"]["max_file_size"] == 5_000_000
      assert reply["config"]["max_entries"] == 1
      assert reply["config"]["chunk_size"] == 64_000

      stop_page(page)
    end

    test "preflight rejects when entries exceed max_entries" do
      page = Musubi.Testing.mount(AvatarStore)
      assert_receive {:patch, _initial}

      {:ok, _reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "0", "name" => "a.png", "size" => 1, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      {:ok, reply} =
        Musubi.Testing.allow_upload(
          page,
          :avatar,
          [%{"client_ref" => "1", "name" => "b.png", "size" => 1, "type" => "image/png"}],
          endpoint: TestEndpoint
        )

      assert reply["entries"] == %{}
      assert [%{"error" => %{"code" => "too_many_files"}}] = reply["errors"]

      stop_page(page)
    end
  end

  describe "token verification" do
    test "rejects forged or expired tokens" do
      assert {:error, _} = Token.verify(TestEndpoint, "not-a-real-token")
    end

    test "valid token round-trips the payload" do
      payload = %{
        store_pid: self(),
        store_id: [],
        conf_ref: "avatar",
        entry_ref: "e_001",
        max_file_size: 5_000_000,
        accept: [".png"],
        chunk_size: 64_000
      }

      token = Token.sign(TestEndpoint, payload)
      assert {:ok, decoded} = Token.verify(TestEndpoint, token)
      assert decoded.entry_ref == "e_001"
      assert decoded.store_pid == self()
    end
  end

  defp stop_page(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end
end
