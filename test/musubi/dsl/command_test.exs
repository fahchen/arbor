defmodule Musubi.DSL.CommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule BlockFormStore do
    @moduledoc false
    use Musubi.Store

    state do
      field :ok, boolean()
    end

    command :no_block

    command :payload_only do
      payload do
        field :sku, String.t()
      end
    end

    command :reply_only do
      reply do
        field :result, %{ok: true} | %{error: String.t()}
      end
    end

    command :full do
      payload do
        field :title, String.t()
        field :body, String.t() | nil, doc: "optional body"
      end

      reply do
        field :ok, boolean()
      end
    end

    command :empty_blocks do
      payload do
      end

      reply do
      end
    end

    @impl Musubi.Store
    def mount(socket), do: {:ok, socket}
    @impl Musubi.Store
    def render(_socket), do: %{ok: true}
    @impl Musubi.Store
    def handle_command(_name, _payload, socket), do: {:noreply, socket}
  end

  test "command without a block has empty payload + reply field lists" do
    {:ok, %{payload_fields: [], reply_fields: []}} =
      BlockFormStore.__musubi__(:command, :no_block)
  end

  test "payload-only command populates payload_fields, leaves reply_fields empty" do
    {:ok, %{payload_fields: [%{name: :sku}], reply_fields: []}} =
      BlockFormStore.__musubi__(:command, :payload_only)
  end

  test "reply-only command populates reply_fields, leaves payload_fields empty" do
    {:ok, %{payload_fields: [], reply_fields: [%{name: :result}]}} =
      BlockFormStore.__musubi__(:command, :reply_only)
  end

  test "full command captures both lists with doc opts preserved" do
    {:ok, %{payload_fields: payload_fields, reply_fields: reply_fields}} =
      BlockFormStore.__musubi__(:command, :full)

    assert [
             %{name: :title, opts: []},
             %{name: :body, opts: [doc: "optional body"]}
           ] = payload_fields

    assert [%{name: :ok}] = reply_fields
  end

  test "empty payload do / reply do blocks behave like omitted blocks" do
    {:ok, %{payload_fields: [], reply_fields: []}} =
      BlockFormStore.__musubi__(:command, :empty_blocks)
  end

  test "non-binary :doc value raises a compile-time error" do
    source = """
    defmodule Musubi.TestSupport.BadDocOpt do
      @moduledoc false
      use Musubi.Store

      state do
        field :ok, boolean()
      end

      command :bad do
        payload do
          field :title, String.t(), doc: 123
        end
      end

      @impl Musubi.Store
      def mount(socket), do: {:ok, socket}
      @impl Musubi.Store
      def render(_socket), do: %{ok: true}
      @impl Musubi.Store
      def handle_command(_n, _p, socket), do: {:noreply, socket}
    end
    """

    capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/`:doc` must be a binary.*123/, fn ->
        Code.compile_string(source)
      end
    end)
  end

  test "unsupported field opt raises a compile-time error" do
    source = """
    defmodule Musubi.TestSupport.BadFieldOpt do
      @moduledoc false
      use Musubi.Store

      state do
        field :ok, boolean()
      end

      command :bad do
        payload do
          field :title, String.t(), required: true
        end
      end

      @impl Musubi.Store
      def mount(socket), do: {:ok, socket}
      @impl Musubi.Store
      def render(_socket), do: %{ok: true}
      @impl Musubi.Store
      def handle_command(_n, _p, socket), do: {:noreply, socket}
    end
    """

    capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/unsupported command field opts/, fn ->
        Code.compile_string(source)
      end
    end)
  end

  test "field outside payload/reply blocks raises at compile time" do
    source = """
    defmodule Musubi.TestSupport.StrayField do
      @moduledoc false
      use Musubi.Store

      state do
        field :ok, boolean()
      end

      command :bad do
        field :nope, String.t()
      end

      @impl Musubi.Store
      def mount(socket), do: {:ok, socket}
      @impl Musubi.Store
      def render(_socket), do: %{ok: true}
      @impl Musubi.Store
      def handle_command(_n, _p, socket), do: {:noreply, socket}
    end
    """

    capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/`field` is only valid inside/, fn ->
        Code.compile_string(source)
      end
    end)
  end
end
