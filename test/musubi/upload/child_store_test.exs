defmodule Musubi.Upload.ChildStoreTest do
  @moduledoc """
  BDR-0028: per-item upload capability uses a child store per item.
  Each child declares its own `upload :name` at the top level; every
  `upload_op` carries the child's `store_id` so routing is unambiguous.
  """

  use ExUnit.Case, async: true

  defmodule TestEndpoint do
    use Phoenix.Endpoint, otp_app: :musubi
  end

  defmodule CartLineStore do
    use Musubi.Store

    attr :line_id, String.t(), required: true

    state do
      field :line_id, String.t()
    end

    upload(:attachment, accept: ~w(.pdf), max_entries: 1, max_file_size: 1_000_000)

    @impl Musubi.Store
    def init(socket) do
      {:ok, assign(socket, :line_id, socket.assigns.line_id)}
    end

    @impl Musubi.Store
    def render(socket), do: %{line_id: socket.assigns.line_id}

    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}
  end

  defmodule CartStore do
    use Musubi.Store, root: true

    state do
      field :lines, list(CartLineStore.state())
    end

    @impl Musubi.Store
    def mount(_params, socket) do
      {:ok, assign(socket, :lines, ["1", "2"])}
    end

    @impl Musubi.Store
    def render(socket) do
      lines =
        Enum.map(socket.assigns.lines, fn line_id ->
          child(CartLineStore, id: "line-#{line_id}", line_id: line_id)
        end)

      %{lines: lines}
    end

    @impl Musubi.Store
    def handle_command(_n, _p, s), do: {:noreply, s}
  end

  setup_all do
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    start_supervised!(TestEndpoint)
    :ok
  end

  test "each child render output carries its own upload marker" do
    page = Musubi.Testing.mount(CartStore)
    assert_receive {:patch, envelope}

    [%{op: "replace", path: "", value: wire}] = envelope.ops

    [line1, line2] = wire["lines"]
    assert line1["__musubi_store_id__"] == ["lines", "line-1"]
    assert line2["__musubi_store_id__"] == ["lines", "line-2"]
    assert line1["attachment"] == %{"__musubi_upload__" => "attachment"}
    assert line2["attachment"] == %{"__musubi_upload__" => "attachment"}

    stop_page(page)
  end

  test "initial envelope emits one config op per child store with its own store_id" do
    page = Musubi.Testing.mount(CartStore)
    assert_receive {:patch, envelope}

    configs = Enum.filter(envelope.upload_ops, &(&1.op == "config"))
    assert length(configs) == 2

    store_ids = configs |> Enum.map(& &1.store_id) |> Enum.sort()
    assert store_ids == [["lines", "line-1"], ["lines", "line-2"]]

    Enum.each(configs, fn op ->
      assert op.upload == "attachment"
      assert op.config["max_entries"] == 1
      assert op.config["accept"] == [".pdf"]
    end)

    stop_page(page)
  end

  test "allow_upload on a child store_id signs a token bound to that child" do
    page = Musubi.Testing.mount(CartStore)
    assert_receive {:patch, _initial}

    entries = [
      %{"client_ref" => "0", "name" => "spec.pdf", "size" => 1000, "type" => "application/pdf"}
    ]

    {:ok, reply} =
      Musubi.Testing.allow_upload(
        page,
        :attachment,
        entries,
        [endpoint: TestEndpoint],
        ["lines", "line-2"]
      )

    [{"0", entry}] = Enum.to_list(reply["entries"])
    assert entry["type"] == "channel"

    {:ok, payload} = Musubi.Upload.Token.verify(TestEndpoint, entry["token"])
    assert payload.store_id == ["lines", "line-2"]
    assert payload.conf_ref == "attachment"
    assert payload.entry_ref == entry["entry_ref"]
    assert payload.store_pid == page.pid

    # The corresponding {op: add} carries store_id ["lines", "line-2"].
    assert_receive {:patch, envelope}

    add =
      Enum.find(envelope.upload_ops, fn op ->
        op.op == "add" and op.ref == entry["entry_ref"]
      end)

    assert add
    assert add.store_id == ["lines", "line-2"]
    assert add.upload == "attachment"

    stop_page(page)
  end

  test "two children with the same upload name route ops by store_id" do
    page = Musubi.Testing.mount(CartStore)
    assert_receive {:patch, _initial}

    {:ok, reply1} =
      Musubi.Testing.allow_upload(
        page,
        :attachment,
        [%{"client_ref" => "0", "name" => "a.pdf", "size" => 1, "type" => "application/pdf"}],
        [endpoint: TestEndpoint],
        ["lines", "line-1"]
      )

    assert_receive {:patch, _add1}

    {:ok, reply2} =
      Musubi.Testing.allow_upload(
        page,
        :attachment,
        [%{"client_ref" => "0", "name" => "b.pdf", "size" => 1, "type" => "application/pdf"}],
        [endpoint: TestEndpoint],
        ["lines", "line-2"]
      )

    assert_receive {:patch, _add2}

    [{_cref, %{"entry_ref" => ref1}}] = Enum.to_list(reply1["entries"])
    [{_cref, %{"entry_ref" => ref2}}] = Enum.to_list(reply2["entries"])

    Musubi.Testing.simulate_upload(page, :attachment, ref1, 1, ["lines", "line-1"])
    assert_receive {:patch, envelope1}

    Musubi.Testing.simulate_upload(page, :attachment, ref2, 1, ["lines", "line-2"])
    assert_receive {:patch, envelope2}

    line1_ops = Enum.filter(envelope1.upload_ops, &(&1.store_id == ["lines", "line-1"]))
    line2_ops = Enum.filter(envelope2.upload_ops, &(&1.store_id == ["lines", "line-2"]))

    assert Enum.any?(line1_ops, &(&1.op == "complete" and &1.ref == ref1))
    assert Enum.any?(line2_ops, &(&1.op == "complete" and &1.ref == ref2))

    # No cross-talk: each envelope only references its own line.
    refute Enum.any?(envelope1.upload_ops, &(&1.store_id == ["lines", "line-2"]))
    refute Enum.any?(envelope2.upload_ops, &(&1.store_id == ["lines", "line-1"]))

    stop_page(page)
  end

  defp stop_page(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end
end
