defmodule Arbor.Plugin.StateField do
  @moduledoc false

  use TypedStructor.Plugin

  alias Arbor.Plugin.Normalize

  @type field_definition :: Normalize.field_definition()
  @type stream_definition :: %{
          name: atom(),
          item_type: Macro.t(),
          item_key: Macro.t(),
          limit: integer() | nil,
          opts: keyword()
        }

  @spec stream_fields([field_definition()]) :: [stream_definition()]
  def stream_fields(fields) do
    Enum.flat_map(fields, fn %{name: name, type: type, opts: opts} ->
      case stream_item_type(type) do
        {:ok, item_type} ->
          item_key = Keyword.get(opts, :item_key, default_item_key_ast(name))
          limit = normalize_literal_opt(Keyword.get(opts, :limit))

          [
            %{
              name: name,
              item_type: item_type,
              item_key: item_key,
              limit: limit,
              opts:
                opts
                |> Keyword.put_new(:item_key, item_key)
                |> Keyword.update(:limit, nil, &normalize_literal_opt/1)
            }
          ]

        :error ->
          []
      end
    end)
  end

  @spec stream_item_type(Macro.t()) :: {:ok, Macro.t()} | :error
  def stream_item_type({:stream, _meta, [item_type]}), do: {:ok, item_type}
  def stream_item_type(_other), do: :error

  @spec default_item_key_ast(atom()) :: Macro.t()
  def default_item_key_ast(name) when is_atom(name) do
    quote do
      &"#{unquote(name)}-#{&1.id}"
    end
  end

  @spec normalize_literal_opt(term()) :: term()
  def normalize_literal_opt(nil), do: nil

  def normalize_literal_opt(value) do
    case Code.eval_quoted(value, [], __ENV__) do
      {evaluated, []} -> evaluated
      _other -> value
    end
  rescue
    _error -> value
  end

  @impl TypedStructor.Plugin
  defmacro after_definition(definition, _opts) do
    quote bind_quoted: [definition: definition] do
      @__arbor_fields__ Arbor.Plugin.Normalize.fields(definition.fields)
    end
  end
end
