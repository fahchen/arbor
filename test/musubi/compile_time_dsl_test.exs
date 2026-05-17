defmodule Musubi.TestSupport.MoneyState do
  @moduledoc false

  use Musubi.State

  state do
    field :amount, integer()
  end
end

defmodule Musubi.TestSupport.ChildStore do
  @moduledoc false

  use Musubi.Store

  state do
    field :id, String.t()
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, socket}
  @impl Musubi.Store
  def render(socket), do: %{id: Map.get(socket.assigns, :id, socket.id || "")}
  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end

defmodule Musubi.TestSupport.ExampleStore do
  @moduledoc false

  use Musubi.Store

  alias Musubi.TestSupport.ChildStore
  alias Musubi.TestSupport.MoneyState

  state do
    stream(:messages, MoneyState.t(), item_key: &"msg-#{&1.amount}", limit: -100)
    stream(:events, String.t())
    field :load_state, Musubi.AsyncResult.of(stream(MoneyState.t()))
    field :child, ChildStore.state()
    field :money, MoneyState.t()
    field :status, %{type: :active} | %{type: :paused, value: integer()}
    field :tags, list(String.t())
    field :meta, map()
  end

  command(:ping)

  command :select_product do
    payload(:id, String.t())
  end

  command :apply_filters do
    payload(:status, %{type: :active} | %{type: :paused, value: integer()})
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, socket}

  @impl Musubi.Store
  def render(_socket) do
    %{
      messages: stream(:messages),
      events: stream(:events),
      load_state: async_stream(:load_state),
      child: %{id: "child"},
      money: %{amount: 0},
      status: %{type: :active},
      tags: [],
      meta: %{}
    }
  end

  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end

defmodule Musubi.TestSupport.ExampleState do
  @moduledoc false

  use Musubi.State

  alias Musubi.TestSupport.MoneyState

  state do
    field :money, MoneyState.t()
  end
end

defmodule Musubi.TestSupport.StreamOnlyStore do
  @moduledoc false

  use Musubi.Store

  state do
    stream(:notes, String.t(), limit: 50)
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, socket}
  @impl Musubi.Store
  def render(_socket), do: %{notes: stream(:notes)}
  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end

defmodule Musubi.TestSupport.AsyncStreamStore do
  @moduledoc false

  use Musubi.Store

  alias Musubi.TestSupport.MoneyState

  state do
    stream_async(:loaded, MoneyState.t(),
      item_key: &"loaded-#{&1.amount}",
      limit: -200
    )
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, socket}
  @impl Musubi.Store
  def render(_socket) do
    %{loaded: async_stream(:loaded)}
  end

  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end

defmodule Musubi.TestSupport.StreamStateModule do
  @moduledoc false

  use Musubi.State

  state do
    stream(:lines, String.t(), limit: 25)
  end
end

defmodule Musubi.TestSupport.NestedSchemaStore do
  @moduledoc false

  use Musubi.Store

  state do
    field :message do
      field :body, String.t()
    end

    field :feed do
      stream :messages do
        field :body, String.t()
      end
    end
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, socket}

  @impl Musubi.Store
  def render(_socket) do
    %{message: %{body: "hi"}, feed: %{messages: stream(:messages)}}
  end

  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end

defmodule Musubi.TestSupport.MultiCommandStore do
  @moduledoc false

  use Musubi.Store

  state do
    field :id, String.t()
  end

  command :select_product do
    payload(:id, String.t())
  end

  command :apply_filters do
    payload(:status, %{type: :active} | %{type: :paused, value: integer()})
    payload(:include_archived, boolean())
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, socket}
  @impl Musubi.Store
  def render(socket), do: %{id: Map.get(socket.assigns, :id, "")}
  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end

defmodule Musubi.CompileTimeDslTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Musubi.TestSupport.ExampleState
  alias Musubi.TestSupport.ExampleStore
  alias Musubi.TestSupport.MultiCommandStore

  test "store reflection exposes fields, commands, streams, and attrs" do
    assert [:messages, :events, :load_state, :child, :money, :status, :tags, :meta] =
             Enum.map(ExampleStore.__musubi__(:fields), & &1.name)

    assert [
             %{name: :ping, payload_fields: [], opts: []},
             %{name: :select_product, payload_fields: [%{name: :id, opts: []}], opts: []},
             %{name: :apply_filters, payload_fields: [%{name: :status, opts: []}], opts: []}
           ] = ExampleStore.__musubi__(:commands)

    assert [
             %{
               name: :messages,
               item_type:
                 {{:., _messages_dot_meta,
                   [{:__aliases__, _messages_alias_meta, [:MoneyState]}, :t]},
                  _messages_call_meta, []},
               item_key: {:&, _messages_capture_meta, _messages_capture_body},
               limit: -100,
               opts: message_stream_opts
             },
             %{
               name: :events,
               item_type:
                 {{:., _events_dot_meta, [{:__aliases__, _events_alias_meta, [:String]}, :t]},
                  _events_call_meta, []},
               item_key: default_item_key_ast,
               limit: nil,
               opts: event_stream_opts
             },
             %{
               name: :load_state,
               path: ["load_state", "result"],
               item_type:
                 {{:., _load_dot_meta, [{:__aliases__, _load_alias_meta, [:MoneyState]}, :t]},
                  _load_call_meta, []},
               item_key: load_state_item_key_ast,
               limit: nil,
               opts: load_state_stream_opts
             }
           ] = ExampleStore.__musubi__(:streams)

    assert {:&, _capture_meta, _capture_body} = Keyword.fetch!(message_stream_opts, :item_key)
    assert -100 = Keyword.fetch!(message_stream_opts, :limit)

    assert {:&, _default_capture_meta, _default_capture_body} =
             Keyword.fetch!(event_stream_opts, :item_key)

    assert nil == Keyword.get(event_stream_opts, :limit)
    assert {:&, _default_ast_meta, _default_ast_body} = default_item_key_ast
    assert {:&, _load_state_meta, _load_state_body} = load_state_item_key_ast
    assert nil == Keyword.get(load_state_stream_opts, :limit)

    assert [] = ExampleStore.__musubi__(:attrs)
  end

  test "field type reflection returns the quoted ast for a single field" do
    assert {:stream, _stream_meta, [_message_type]} = ExampleStore.__musubi__(:type, :messages)

    assert {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Musubi, :AsyncResult]}, :of]},
            _call_meta, [_load_arg]} =
             ExampleStore.__musubi__(:type, :load_state)

    assert {{:., _child_dot_meta, [{:__aliases__, _child_alias_meta, [:ChildStore]}, :state]},
            _child_call_meta, []} =
             ExampleStore.__musubi__(:type, :child)
  end

  test "state modules expose reflection and reserve empty store-only metadata" do
    assert [%{name: :money, opts: []}] = ExampleState.__musubi__(:fields)
    assert [] = ExampleState.__musubi__(:commands)
    assert [] = ExampleState.__musubi__(:streams)
    assert [] = ExampleState.__musubi__(:attrs)
  end

  test "reserved musubi command prefix fails at compile time" do
    source = """
    defmodule Musubi.TestSupport.InvalidCommandStore do
      @moduledoc false
      use Musubi.Store

      state do
        field :id, String.t()
      end

      command :\"musubi:reload\"
    end
    """

    capture_io(:stderr, fn ->
      assert_raise ArgumentError, ~r/reserved musubi:/, fn ->
        Code.compile_string(source)
      end
    end)
  end

  test "payload outside a command block fails at compile time" do
    source = """
    defmodule Musubi.TestSupport.InvalidPayloadStore do
      @moduledoc false
      use Musubi.Store

      state do
        field :id, String.t()
      end

      payload :id, String.t()
    end
    """

    capture_io(:stderr, fn ->
      assert_raise CompileError, fn ->
        Code.compile_string(source)
      end
    end)
  end

  test "missing required Musubi.Store callbacks warn at compile time" do
    source = """
    defmodule Musubi.TestSupport.MissingStoreCallbacks do
      @moduledoc false
      use Musubi.Store

      state do
        field :id, String.t()
      end
    end
    """

    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string(source)
      end)

    assert stderr =~ "function render/1 required by behaviour Musubi.Store is not implemented"

    assert stderr =~
             "function handle_command/3 required by behaviour Musubi.Store is not implemented"
  end

  test "non-root stores cannot define mount/2" do
    source = """
    defmodule Musubi.TestSupport.NonRootMountCallbackStore do
      @moduledoc false
      use Musubi.Store

      state do
        field :id, String.t()
      end

      @impl Musubi.Store
      def mount(_params, socket), do: {:ok, socket}

      @impl Musubi.Store
      def render(_socket), do: %{id: "ok"}

      @impl Musubi.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end
    """

    capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/mount\/2 is only allowed on root Musubi stores/, fn ->
        Code.compile_string(source)
      end
    end)
  end

  test "sockets cannot declare non-root stores as roots" do
    source = """
    defmodule Musubi.TestSupport.NonRootSocketStore do
      @moduledoc false
      use Musubi.Store

      state do
        field :id, String.t()
      end

      @impl Musubi.Store
      def render(_socket), do: %{id: "ok"}

      @impl Musubi.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end

    defmodule Musubi.TestSupport.InvalidRootSocket do
      @moduledoc false
      use Musubi.Socket, roots: [Musubi.TestSupport.NonRootSocketStore]
    end
    """

    assert_raise ArgumentError, ~r/must use Musubi.Store, root: true/, fn ->
      Code.compile_string(source)
    end
  end

  test "sockets wait for root stores compiled in parallel" do
    token = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "musubi_socket_compile_order_#{token}")
    source_dir = Path.join(tmp_dir, "lib")
    ebin_dir = Path.join(tmp_dir, "ebin")

    store_module = Musubi.TestSupport.SocketCompileOrder.RootStore
    socket_module = Musubi.TestSupport.SocketCompileOrder.Socket

    store_path = Path.join(source_dir, "root_store.ex")
    socket_path = Path.join(source_dir, "socket.ex")

    File.mkdir_p!(source_dir)
    File.mkdir_p!(ebin_dir)
    File.write!(store_path, root_store_source(store_module))
    File.write!(socket_path, socket_source(socket_module, store_module))

    try do
      assert {:ok, modules, _warnings} =
               Kernel.ParallelCompiler.compile_to_path([socket_path, store_path], ebin_dir,
                 return_diagnostics: true
               )

      assert store_module in modules
      assert socket_module in modules
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "sockets declare roots as module lists" do
    source = """
    defmodule Musubi.TestSupport.NamedRootSocketStore do
      @moduledoc false
      use Musubi.Store, root: true

      state do
        field :id, String.t()
      end

      @impl Musubi.Store
      def render(_socket), do: %{id: "ok"}

      @impl Musubi.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end

    defmodule Musubi.TestSupport.InvalidNamedRootSocket do
      @moduledoc false
      use Musubi.Socket, roots: [named: Musubi.TestSupport.NamedRootSocketStore]
    end
    """

    assert_raise ArgumentError, ~r/must be a list of StoreModule modules/, fn ->
      Code.compile_string(source)
    end
  end

  describe "stream declarations inside state do" do
    alias Musubi.TestSupport.AsyncStreamStore
    alias Musubi.TestSupport.NestedSchemaStore
    alias Musubi.TestSupport.StreamOnlyStore
    alias Musubi.TestSupport.StreamStateModule

    test "stream/3 inside state do registers a stream slot" do
      # ExampleStore declares direct streams and an async stream field:
      #   stream :messages, MoneyState.t(), item_key: ..., limit: -100
      #   stream :events,   String.t()
      #   field :load_state, AsyncResult.of(stream(MoneyState.t()))
      # Both must round-trip into __musubi__(:streams).
      stream_names = Enum.map(ExampleStore.__musubi__(:streams), & &1.name)

      assert :messages in stream_names
      assert :events in stream_names
      assert :load_state in stream_names
    end

    test "stream fields are also enumerated by __musubi__(:fields)" do
      field_names = Enum.map(ExampleStore.__musubi__(:fields), & &1.name)

      assert :messages in field_names
      assert :events in field_names
    end

    test "stream metadata round-trips item_type AST" do
      messages = Enum.find(ExampleStore.__musubi__(:streams), &(&1.name == :messages))

      # stream :messages, MoneyState.t() → item_type AST is `MoneyState.t()`
      assert {{:., _dot, [{:__aliases__, _alias, [:MoneyState]}, :t]}, _call, []} =
               messages.item_type

      events = Enum.find(ExampleStore.__musubi__(:streams), &(&1.name == :events))

      # stream :events, String.t() → item_type AST is `String.t()`
      assert {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []} =
               events.item_type
    end

    test "stream-only store: stream :notes, String.t(), limit: 50" do
      assert [%{name: :notes, limit: 50, item_type: item_type}] =
               StreamOnlyStore.__musubi__(:streams)

      assert {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []} = item_type
    end

    test "Musubi.State module: stream :lines, String.t(), limit: 25" do
      assert [%{name: :lines, limit: 25, item_type: item_type}] =
               StreamStateModule.__musubi__(:streams)

      assert {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []} = item_type
    end

    test "nested field blocks and inline stream item schemas reflect paths" do
      assert {:ok, %{type: {:%{}, _meta, message_pairs}}} =
               NestedSchemaStore.__musubi__(:field, :message)

      assert Enum.any?(message_pairs, fn
               {:body, {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []}} ->
                 true

               _other ->
                 false
             end)

      assert [%{name: :messages, path: ["feed", "messages"], item_type: item_type}] =
               NestedSchemaStore.__musubi__(:streams)

      assert {:%{}, _meta,
              [{:body, {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []}}]} =
               item_type
    end

    test "explicit item_key is preserved as a quoted capture, not evaluated" do
      assert [%{name: :messages, item_key: item_key}] =
               Enum.filter(ExampleStore.__musubi__(:streams), &(&1.name == :messages))

      refute is_function(item_key),
             "item_key must remain quoted AST until reflection consumers eval it"

      assert {:&, _meta, _body} = item_key
    end

    test "default item_key falls back to a stream-name-prefixed capture" do
      assert [%{name: :events, item_key: default_item_key}] =
               Enum.filter(ExampleStore.__musubi__(:streams), &(&1.name == :events))

      assert {:&, _meta, _body} = default_item_key
    end

    test "limit is normalized into a literal integer (unary-minus survives)" do
      assert %{limit: -100} =
               Enum.find(ExampleStore.__musubi__(:streams), &(&1.name == :messages))

      assert %{limit: nil} =
               Enum.find(ExampleStore.__musubi__(:streams), &(&1.name == :events))
    end

    test "stream fields produce a stream(...) type AST visible via __musubi__(:type, name)" do
      assert {:stream, _meta, [_inner]} = ExampleStore.__musubi__(:type, :messages)
      assert {:stream, _meta, [_inner]} = ExampleStore.__musubi__(:type, :events)
    end

    test "stream_async/3 expands to AsyncResult.of(stream(T))" do
      assert {{:., _dot, [{:__aliases__, _alias, [:Musubi, :AsyncResult]}, :of]}, _call,
              [{:stream, _stream_meta, [_inner]}]} =
               AsyncStreamStore.__musubi__(:type, :loaded)
    end

    test "store with only a stream field reflects correctly" do
      assert [%{name: :notes, limit: 50}] = StreamOnlyStore.__musubi__(:streams)
      assert {:stream, _meta, [_string_type]} = StreamOnlyStore.__musubi__(:type, :notes)
    end

    test "AsyncResult.of(stream(T)) composite is registered as an async stream slot" do
      assert [
               %{
                 name: :loaded,
                 path: ["loaded", "result"],
                 limit: -200,
                 item_key: {:&, _meta, _body}
               }
             ] = AsyncStreamStore.__musubi__(:streams)

      assert {{:., _meta, [{:__aliases__, _alias_meta, [:Musubi, :AsyncResult]}, :of]},
              _call_meta, [_inner]} = AsyncStreamStore.__musubi__(:type, :loaded)
    end

    test "Musubi.State modules support stream fields" do
      assert [%{name: :lines, limit: 25}] = StreamStateModule.__musubi__(:streams)
    end

    test "non-stream fields are excluded from __musubi__(:streams)" do
      stream_names = Enum.map(ExampleStore.__musubi__(:streams), & &1.name)

      refute :child in stream_names
      refute :money in stream_names
      refute :status in stream_names
      refute :tags in stream_names
      refute :meta in stream_names
    end
  end

  test "multiple command payload blocks accumulate independently" do
    assert [
             %{name: :select_product, payload_fields: [%{name: :id, opts: []}], opts: []},
             %{
               name: :apply_filters,
               payload_fields: [
                 %{name: :status, opts: []},
                 %{name: :include_archived, opts: []}
               ],
               opts: []
             }
           ] = MultiCommandStore.__musubi__(:commands)
  end

  test "typespecs are generated for t/0, state/0, and stream/1" do
    assert {:ok, types} = Code.Typespec.fetch_types(Musubi.TestSupport.TypespecProbe)

    type_names =
      Enum.map(types, fn
        {:type, {name, _type_definition, _type_args}} -> name
        {:opaque, {name, _type_definition, _type_args}} -> name
        {:typep, {name, _type_definition, _type_args}} -> name
      end)

    assert :t in type_names
    assert :state in type_names
    assert :stream in type_names
  end

  test "composite-typed fields (stream, AsyncResult.of, unions, child state) round-trip through the t/0 typespec" do
    assert {:ok, types} = Code.Typespec.fetch_types(Musubi.TestSupport.TypespecProbe)

    {:type, t_inner} =
      Enum.find(types, fn
        {:type, {:t, _def, _args}} -> true
        _other -> false
      end)

    rendered = t_inner |> Code.Typespec.type_to_quoted() |> Macro.to_string()

    # stream(T) fields surface as their item-list type via the local stream/1 alias
    assert rendered =~ "messages: stream(String.t())"

    assert rendered =~
             "items: stream(Musubi.TestSupport.TypespecProbeChild.t())"

    # Musubi.AsyncResult.of(...) survives as the composite marker, including
    # nested stream(T) and concrete struct types
    assert rendered =~
             "load_stream: Musubi.AsyncResult.of(stream(Musubi.TestSupport.TypespecProbeChild.t()))"

    assert rendered =~
             "profile: Musubi.AsyncResult.of(Musubi.TestSupport.TypespecProbeChild.t())"

    # Native variant unions survive untouched
    assert rendered =~ "%{type: :active}"
    assert rendered =~ "%{type: :paused, value: integer()}"

    # Child Musubi.State module reference survives the typespec emission
    assert rendered =~ "child: Musubi.TestSupport.TypespecProbeChild.state()"

    # Plain list parameterization survives (rendered in [T] form on the typespec)
    assert rendered =~ "tags: [String.t()]"
  end

  defp root_store_source(module) when is_atom(module) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      use Musubi.Store, root: true

      state do
        field :id, String.t()
      end

      @impl Musubi.Store
      def render(_socket), do: %{id: "ok"}

      @impl Musubi.Store
      def handle_command(_name, _payload, socket), do: {:noreply, socket}
    end
    """
  end

  defp socket_source(socket_module, store_module)
       when is_atom(socket_module) and is_atom(store_module) do
    """
    defmodule #{inspect(socket_module)} do
      @moduledoc false

      use Musubi.Socket, roots: [#{inspect(store_module)}]
    end
    """
  end
end
