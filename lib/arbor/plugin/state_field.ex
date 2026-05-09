defmodule Arbor.Plugin.StateField do
  @moduledoc false

  use TypedStructor.Plugin

  alias Arbor.Plugin.Normalize

  @type field_definition() :: Normalize.field_definition()
  @type stream_definition() :: %{
          name: atom(),
          item_type: Macro.t(),
          item_key: Macro.t(),
          limit: integer() | nil,
          opts: keyword()
        }

  @doc """
  Extracts stream-slot metadata from normalized Arbor field definitions.

  ## Examples

      iex> fields = [%{name: :messages, type: {:stream, [], [String.t()]}, opts: [limit: -10]}]
      iex> [%{name: :messages, limit: -10}] = Arbor.Plugin.StateField.stream_fields(fields)
  """
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

  @doc """
  Returns the item type from a `stream(T)` AST node.

  ## Examples

      iex> Arbor.Plugin.StateField.stream_item_type({:stream, [], [String.t()]})
      {:ok, String.t()}
      iex> Arbor.Plugin.StateField.stream_item_type(String.t())
      :error
  """
  @spec stream_item_type(Macro.t()) :: {:ok, Macro.t()} | :error
  def stream_item_type({:stream, _meta, [item_type]}), do: {:ok, item_type}
  def stream_item_type(_other), do: :error

  @doc """
  Builds the default `item_key` capture for a stream field name.

  ## Examples

      iex> Arbor.Plugin.StateField.default_item_key_ast(:messages) |> Macro.to_string() |> String.starts_with?("&")
      true
  """
  @spec default_item_key_ast(atom()) :: Macro.t()
  def default_item_key_ast(name) when is_atom(name) do
    quote do
      &"#{unquote(name)}-#{&1.id}"
    end
  end

  @doc """
  Evaluates literal quoted opts while leaving dynamic AST untouched.

  ## Examples

      iex> Arbor.Plugin.StateField.normalize_literal_opt(quote(do: -100))
      -100
      iex> fn_ast = {:&, [], [{:<<>>, [], ["msg-", {{:., [], [{:&, [], [1]}, :id]}, [], []}]}]}
      iex> Arbor.Plugin.StateField.normalize_literal_opt(fn_ast)
      fn_ast
  """
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
      Arbor.Plugin.StateField.validate_field_types!(__MODULE__, definition.fields)
      @__arbor_fields__ Arbor.Plugin.Normalize.fields(definition.fields)
    end
  end

  @doc false
  @spec validate_field_types!(module(), [Keyword.t()]) :: :ok
  def validate_field_types!(host_module, fields) when is_atom(host_module) and is_list(fields) do
    Enum.each(fields, fn field ->
      name = Keyword.fetch!(field, :name)
      type = Keyword.fetch!(field, :type)

      unless Arbor.Type.valid_type?(type) do
        raise CompileError,
          description:
            "Arbor #{inspect(host_module)}.#{name}: unsupported field type " <>
              "#{Macro.to_string(type)}. See `Arbor.Type` for the supported AST shapes."
      end
    end)

    :ok
  end
end
