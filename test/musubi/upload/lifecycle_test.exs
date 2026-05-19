defmodule Musubi.Upload.LifecycleTest do
  @moduledoc """
  Covers `spec/domains/uploads/features/lifecycle.feature`: top-level
  DSL declaration, compile-time validation, framework-injected wire
  markers, and the child-store pattern for per-item uploads.
  """

  use ExUnit.Case, async: true

  defmodule SimpleStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:avatar,
      accept: ~w(.jpg .jpeg .png),
      max_entries: 1,
      max_file_size: 5_000_000
    )

    def render(socket), do: %{title: socket.assigns[:title]}
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule MultiStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png))
    upload(:cover, accept: ~w(.jpg))

    def render(_socket), do: %{title: "Hi"}
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule DocStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:doc, accept: ~w(.pdf))

    def render(socket), do: %{title: socket.assigns[:title]}
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule AnyStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:anything, accept: :any)

    def render(socket), do: %{title: socket.assigns[:title]}
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule HandWrittenMarkerStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    upload(:avatar, accept: ~w(.png))

    def render(_socket) do
      %{title: "Hi", avatar: %{"__musubi_upload__" => "avatar"}}
    end

    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  defmodule UnknownMarkerStore do
    use Musubi.Store, root: true

    state do
      field :title, String.t() | nil
    end

    def render(_socket) do
      %{title: "Hi", avatar: %{"__musubi_upload__" => "avatar"}}
    end

    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  describe "upload :name, opts compile-time declaration" do
    test "registers upload config with explicit options" do
      assert {:ok, config} = SimpleStore.__musubi__(:upload, :avatar)
      assert config.accept == [".jpg", ".jpeg", ".png"]
      assert config.max_entries == 1
      assert config.max_file_size == 5_000_000
    end

    test "applies defaults when options omitted" do
      assert {:ok, config} = DocStore.__musubi__(:upload, :doc)
      assert config.accept == [".pdf"]
      assert config.max_entries == 1
      assert config.max_file_size == 8_000_000
      assert config.chunk_size == 64_000
      assert config.chunk_timeout == 10_000
    end

    test ":accept :any records the atom literal" do
      assert {:ok, %{accept: :any}} = AnyStore.__musubi__(:upload, :anything)
    end

    test "reflection lists declared uploads in order" do
      assert [:avatar, :cover] ==
               MultiStore.__musubi__(:uploads) |> Enum.map(& &1.name)
    end
  end

  describe "compile-time validation" do
    test "missing :accept option" do
      assert_raise ArgumentError, ~r/requires the :accept option/, fn ->
        defmodule MissingAccept do
          use Musubi.Store, root: true

          state do
            field :title, String.t()
          end

          upload(:doc, max_entries: 1)

          def render(_socket), do: %{title: "x"}
          def handle_command(_n, _p, s), do: {:noreply, s}
        end
      end
    end

    test "duplicate upload name" do
      assert_raise CompileError, ~r/duplicate upload declaration :avatar/, fn ->
        defmodule DuplicateUpload do
          use Musubi.Store, root: true

          state do
            field :title, String.t()
          end

          upload(:avatar, accept: ~w(.png))
          upload(:avatar, accept: ~w(.jpg))

          def render(_socket), do: %{title: "x"}
          def handle_command(_n, _p, s), do: {:noreply, s}
        end
      end
    end

    test "upload name collides with state field" do
      assert_raise CompileError, ~r/collides with state field/, fn ->
        defmodule CollideUpload do
          use Musubi.Store, root: true

          state do
            field :avatar, String.t()
          end

          upload(:avatar, accept: ~w(.png))

          def render(_socket), do: %{avatar: "x"}
          def handle_command(_n, _p, s), do: {:noreply, s}
        end
      end
    end

    test "upload inside `state do` is rejected" do
      assert_raise CompileError, ~r/upload :avatar not allowed inside/, fn ->
        defmodule InsideState do
          use Musubi.Store, root: true

          state do
            field :title, String.t()
            upload(:avatar, accept: ~w(.png))
          end

          def render(_socket), do: %{title: "x"}
          def handle_command(_n, _p, s), do: {:noreply, s}
        end
      end
    end
  end

  describe "framework marker injection" do
    test "renders upload markers at the store root for every declared upload" do
      page = Musubi.Testing.mount(MultiStore)

      Process.sleep(20)

      # Drain the initial envelope to inspect ops.
      assert_receive {:patch, envelope}

      [%{op: "replace", path: "", value: wire}] = envelope.ops

      assert wire["avatar"] == %{"__musubi_upload__" => "avatar"}
      assert wire["cover"] == %{"__musubi_upload__" => "cover"}
      assert wire["title"] == "Hi"

      :ok = stop_page(page)
    end

    test "raises when render hand-writes a marker" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               GenServer.start(
                 Musubi.Page.Server,
                 {HandWrittenMarkerStore, %{}, %{transport_pid: self()}}
               )

      assert msg =~ "hand-written upload marker"
    end

    test "raises when render references an undeclared upload marker" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               GenServer.start(
                 Musubi.Page.Server,
                 {UnknownMarkerStore, %{}, %{transport_pid: self()}}
               )

      assert msg =~ "unknown upload"
    end
  end

  describe "initial envelope" do
    test "carries one config op per declared upload" do
      page = Musubi.Testing.mount(MultiStore)
      assert_receive {:patch, envelope}

      configs = Enum.filter(envelope.upload_ops, &(&1.op == "config"))
      uploads = Enum.map(configs, & &1.upload) |> Enum.sort()
      assert uploads == ["avatar", "cover"]
      :ok = stop_page(page)
    end
  end

  defp stop_page(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end
end
