defmodule Arbor.TestSupport.MoneyState do
  @moduledoc false

  use Arbor.State

  state do
    field(:amount, integer())
  end
end

defmodule Arbor.TestSupport.ChildStore do
  @moduledoc false

  use Arbor.Store

  state do
    field(:id, String.t())
  end
end

defmodule Arbor.TestSupport.ExampleStore do
  @moduledoc false

  use Arbor.Store

  alias Arbor.TestSupport.ChildStore
  alias Arbor.TestSupport.MoneyState

  state do
    field(:messages, stream(MoneyState.t()), item_key: &"msg-#{&1.amount}", limit: -100)
    field(:events, stream(String.t()))
    field(:load_state, Arbor.AsyncResult.of(stream(MoneyState.t())))
    field(:child, ChildStore.state())
    field(:money, MoneyState.t())
    field(:status, %{type: :active} | %{type: :paused, value: integer()})
    field(:tags, list(String.t()))
    field(:meta, map())
  end

  command(:ping)

  command :select_product do
    payload(:id, String.t())
  end

  command :apply_filters do
    payload(:status, %{type: :active} | %{type: :paused, value: integer()})
  end
end

defmodule Arbor.TestSupport.ExampleState do
  @moduledoc false

  use Arbor.State

  alias Arbor.TestSupport.MoneyState

  state do
    field(:money, MoneyState.t())
  end
end

defmodule Arbor.TestSupport.StreamOnlyStore do
  @moduledoc false

  use Arbor.Store

  state do
    field(:notes, stream(String.t()), limit: 50)
  end
end

defmodule Arbor.TestSupport.AsyncStreamStore do
  @moduledoc false

  use Arbor.Store

  alias Arbor.TestSupport.MoneyState

  state do
    field(:loaded, Arbor.AsyncResult.of(stream(MoneyState.t())),
      item_key: &"loaded-#{&1.amount}",
      limit: -200
    )
  end
end

defmodule Arbor.TestSupport.StreamStateModule do
  @moduledoc false

  use Arbor.State

  state do
    field(:lines, stream(String.t()), limit: 25)
  end
end

defmodule Arbor.TestSupport.MultiCommandStore do
  @moduledoc false

  use Arbor.Store

  state do
    field(:id, String.t())
  end

  command :select_product do
    payload(:id, String.t())
  end

  command :apply_filters do
    payload(:status, %{type: :active} | %{type: :paused, value: integer()})
    payload(:include_archived, boolean())
  end
end

defmodule Arbor.CompileTimeDslTest do
  use ExUnit.Case, async: true

  alias Arbor.TestSupport.ExampleState
  alias Arbor.TestSupport.ExampleStore
  alias Arbor.TestSupport.MultiCommandStore

  test "store reflection exposes fields, commands, streams, and attrs" do
    assert [:messages, :events, :load_state, :child, :money, :status, :tags, :meta] =
             Enum.map(ExampleStore.__arbor__(:fields), & &1.name)

    assert [
             %{name: :ping, payload_fields: [], opts: []},
             %{name: :select_product, payload_fields: [%{name: :id, opts: []}], opts: []},
             %{name: :apply_filters, payload_fields: [%{name: :status, opts: []}], opts: []}
           ] = ExampleStore.__arbor__(:commands)

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
             }
           ] = ExampleStore.__arbor__(:streams)

    assert {:&, _capture_meta, _capture_body} = Keyword.fetch!(message_stream_opts, :item_key)
    assert -100 = Keyword.fetch!(message_stream_opts, :limit)

    assert {:&, _default_capture_meta, _default_capture_body} =
             Keyword.fetch!(event_stream_opts, :item_key)

    assert nil == Keyword.get(event_stream_opts, :limit)
    assert {:&, _default_ast_meta, _default_ast_body} = default_item_key_ast

    assert [] = ExampleStore.__arbor__(:attrs)
  end

  test "field type reflection returns the quoted ast for a single field" do
    assert {:stream, _stream_meta, [_message_type]} = ExampleStore.__arbor__(:type, :messages)

    assert {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Arbor, :AsyncResult]}, :of]},
            _call_meta, [_load_arg]} =
             ExampleStore.__arbor__(:type, :load_state)

    assert {{:., _child_dot_meta, [{:__aliases__, _child_alias_meta, [:ChildStore]}, :state]},
            _child_call_meta, []} =
             ExampleStore.__arbor__(:type, :child)
  end

  test "state modules expose reflection and reserve empty store-only metadata" do
    assert [%{name: :money, opts: []}] = ExampleState.__arbor__(:fields)
    assert [] = ExampleState.__arbor__(:commands)
    assert [] = ExampleState.__arbor__(:streams)
    assert [] = ExampleState.__arbor__(:attrs)
  end

  test "reserved arbor command prefix fails at compile time" do
    source = """
    defmodule Arbor.TestSupport.InvalidCommandStore do
      @moduledoc false
      use Arbor.Store

      state do
        field :id, String.t()
      end

      command :\"arbor:reload\"
    end
    """

    assert_raise ArgumentError, ~r/reserved arbor:/, fn ->
      Code.compile_string(source)
    end
  end

  test "payload outside a command block fails at compile time" do
    source = """
    defmodule Arbor.TestSupport.InvalidPayloadStore do
      @moduledoc false
      use Arbor.Store

      state do
        field :id, String.t()
      end

      payload :id, String.t()
    end
    """

    assert_raise CompileError, fn ->
      Code.compile_string(source)
    end
  end

  describe "stream declarations inside state do" do
    alias Arbor.TestSupport.AsyncStreamStore
    alias Arbor.TestSupport.StreamOnlyStore
    alias Arbor.TestSupport.StreamStateModule

    test "field :name, stream(T) inside state do registers a stream slot" do
      # ExampleStore declares two stream fields inside its state do block:
      #   field :messages, stream(MoneyState.t()), item_key: ..., limit: -100
      #   field :events,   stream(String.t())
      # Both must round-trip into __arbor__(:streams).
      stream_names = Enum.map(ExampleStore.__arbor__(:streams), & &1.name)

      assert :messages in stream_names
      assert :events in stream_names
    end

    test "stream fields are also enumerated by __arbor__(:fields)" do
      field_names = Enum.map(ExampleStore.__arbor__(:fields), & &1.name)

      assert :messages in field_names
      assert :events in field_names
    end

    test "stream metadata round-trips item_type AST" do
      messages =
        ExampleStore.__arbor__(:streams)
        |> Enum.find(&(&1.name == :messages))

      # field :messages, stream(MoneyState.t()) → item_type AST is `MoneyState.t()`
      assert {{:., _dot, [{:__aliases__, _alias, [:MoneyState]}, :t]}, _call, []} =
               messages.item_type

      events = Enum.find(ExampleStore.__arbor__(:streams), &(&1.name == :events))

      # field :events, stream(String.t()) → item_type AST is `String.t()`
      assert {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []} =
               events.item_type
    end

    test "stream-only store: field :notes, stream(String.t()), limit: 50" do
      assert [%{name: :notes, limit: 50, item_type: item_type}] =
               StreamOnlyStore.__arbor__(:streams)

      assert {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []} = item_type
    end

    test "Arbor.State module: field :lines, stream(String.t()), limit: 25" do
      assert [%{name: :lines, limit: 25, item_type: item_type}] =
               StreamStateModule.__arbor__(:streams)

      assert {{:., _dot, [{:__aliases__, _alias, [:String]}, :t]}, _call, []} = item_type
    end

    test "explicit item_key is preserved as a quoted capture, not evaluated" do
      assert [%{name: :messages, item_key: item_key}] =
               Enum.filter(ExampleStore.__arbor__(:streams), &(&1.name == :messages))

      refute is_function(item_key),
             "item_key must remain quoted AST until reflection consumers eval it"

      assert {:&, _meta, _body} = item_key
    end

    test "default item_key falls back to a stream-name-prefixed capture" do
      assert [%{name: :events, item_key: default_item_key}] =
               Enum.filter(ExampleStore.__arbor__(:streams), &(&1.name == :events))

      assert {:&, _meta, _body} = default_item_key
    end

    test "limit is normalized into a literal integer (unary-minus survives)" do
      assert %{limit: -100} =
               Enum.find(ExampleStore.__arbor__(:streams), &(&1.name == :messages))

      assert %{limit: nil} =
               Enum.find(ExampleStore.__arbor__(:streams), &(&1.name == :events))
    end

    test "stream fields produce a stream(...) type AST visible via __arbor__(:type, name)" do
      assert {:stream, _meta, [_inner]} = ExampleStore.__arbor__(:type, :messages)
      assert {:stream, _meta, [_inner]} = ExampleStore.__arbor__(:type, :events)
    end

    test "store with only a stream field reflects correctly" do
      assert [%{name: :notes, limit: 50}] = StreamOnlyStore.__arbor__(:streams)
      assert {:stream, _meta, [_string_type]} = StreamOnlyStore.__arbor__(:type, :notes)
    end

    test "AsyncResult.of(stream(T)) composite is NOT registered as a stream slot in M1" do
      # M1 scope: only direct `stream(T)` field types register a stream slot.
      # `AsyncResult.of(stream(T))` is the wire shape consumed by `stream_async/4`
      # (M5), which will register the slot at runtime via the async pipeline.
      assert [] = AsyncStreamStore.__arbor__(:streams)

      assert {{:., _meta, [{:__aliases__, _alias_meta, [:Arbor, :AsyncResult]}, :of]}, _call_meta,
              [_inner]} = AsyncStreamStore.__arbor__(:type, :loaded)
    end

    test "Arbor.State modules support stream fields" do
      assert [%{name: :lines, limit: 25}] = StreamStateModule.__arbor__(:streams)
    end

    test "non-stream fields are excluded from __arbor__(:streams)" do
      stream_names = Enum.map(ExampleStore.__arbor__(:streams), & &1.name)

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
           ] = MultiCommandStore.__arbor__(:commands)
  end

  test "typespecs are generated for t/0, state/0, and stream/1" do
    assert {:ok, types} = Code.Typespec.fetch_types(Arbor.TestSupport.TypespecProbe)

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
end
