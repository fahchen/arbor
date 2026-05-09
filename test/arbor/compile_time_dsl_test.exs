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
