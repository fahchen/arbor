defmodule Musubi.Plugin.StateField do
  @moduledoc false

  use TypedStructor.Plugin

  alias Musubi.Plugin.Normalize

  @type field_definition() :: Normalize.field_definition()
  @type stream_definition() :: %{
          name: atom(),
          path: [String.t()],
          item_type: Macro.t(),
          item_key: Macro.t(),
          limit: integer() | nil,
          opts: keyword()
        }

  @doc """
  Extracts stream-slot metadata from normalized Musubi field definitions.

  ## Examples

      iex> fields = [%{name: :messages, type: {:stream, [], [String.t()]}, opts: [limit: -10]}]
      iex> [%{name: :messages, path: ["messages"], limit: -10}] = Musubi.Plugin.StateField.stream_fields(fields)
  """
  @spec stream_fields([field_definition()]) :: [stream_definition()]
  def stream_fields(fields) do
    fields
    |> Enum.flat_map(fn %{name: name, type: type, opts: opts} ->
      stream_fields_from_type(name, type, opts, [Atom.to_string(name)])
    end)
    |> validate_unique_stream_names!()
  end

  @doc """
  Extracts the item type from a `stream(T)` AST node.

  ## Examples

      iex> Musubi.Plugin.StateField.stream_item_type({:stream, [], [String.t()]})
      {:ok, String.t()}
      iex> Musubi.Plugin.StateField.stream_item_type(String.t())
      :error
  """
  @spec stream_item_type(Macro.t()) :: {:ok, Macro.t()} | :error
  def stream_item_type({:stream, _meta, [item_type]}), do: {:ok, item_type}

  def stream_item_type({{:., _dot, [aliased, :of]}, _call, [{:stream, _meta, [item_type]}]}) do
    if async_result_alias?(aliased), do: {:ok, item_type}, else: :error
  end

  def stream_item_type(_other), do: :error

  @doc """
  Builds the default `item_key` capture for a stream field name.

  ## Examples

      iex> Musubi.Plugin.StateField.default_item_key_ast(:messages) |> Macro.to_string() |> String.starts_with?("&")
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

      iex> Musubi.Plugin.StateField.normalize_literal_opt(quote(do: -100))
      -100
      iex> fn_ast = {:&, [], [{:<<>>, [], ["msg-", {{:., [], [{:&, [], [1]}, :id]}, [], []}]}]}
      iex> Musubi.Plugin.StateField.normalize_literal_opt(fn_ast)
      fn_ast
  """
  @typep literal_opt() :: Macro.t() | integer() | nil

  @spec normalize_literal_opt(literal_opt()) :: literal_opt()
  def normalize_literal_opt(nil), do: nil
  def normalize_literal_opt(value) when is_integer(value), do: value

  def normalize_literal_opt({:-, _meta, [value]}) when is_integer(value), do: -value
  def normalize_literal_opt({:+, _meta, [value]}) when is_integer(value), do: value
  def normalize_literal_opt(value), do: value

  @impl TypedStructor.Plugin
  defmacro after_definition(definition, _opts) do
    quote bind_quoted: [definition: definition] do
      Musubi.Plugin.StateField.validate_field_types!(__MODULE__, definition.fields)
      @__musubi_fields__ Musubi.Plugin.Normalize.fields(definition.fields)
    end
  end

  @doc false
  @spec validate_field_types!(module(), [Keyword.t()]) :: :ok
  def validate_field_types!(host_module, fields) when is_atom(host_module) and is_list(fields) do
    Enum.each(fields, fn field ->
      name = Keyword.fetch!(field, :name)
      type = Keyword.fetch!(field, :type)

      unless Musubi.Type.valid_type?(type) do
        raise CompileError,
          description:
            "Musubi #{inspect(host_module)}.#{name}: unsupported field type " <>
              "#{Macro.to_string(type)}. See `Musubi.Type` for the supported AST shapes."
      end
    end)

    :ok
  end

  @spec stream_fields_from_type(atom(), Macro.t(), keyword(), [String.t()]) ::
          [stream_definition()]
  defp stream_fields_from_type(name, type, opts, path) do
    nested_opts = Musubi.DSL.Schema.stream_opts(type)
    opts = if nested_opts == [], do: opts, else: nested_opts

    case stream_item_type(type) do
      {:ok, item_type} ->
        stream_path = if async_stream_type?(type), do: ["result" | path], else: path
        [build_stream_definition(name, item_type, opts, stream_path)]

      :error ->
        nested_stream_fields(type, path)
    end
  end

  @spec nested_stream_fields(Macro.t(), [String.t()]) :: [stream_definition()]
  defp nested_stream_fields({:%{}, _meta, pairs}, path) when is_list(pairs) do
    Enum.flat_map(pairs, fn
      {name, nested_type} when is_atom(name) ->
        stream_fields_from_type(name, nested_type, [], [Atom.to_string(name) | path])

      _other ->
        []
    end)
  end

  defp nested_stream_fields(_type, _path), do: []

  @spec async_stream_type?(Macro.t()) :: boolean()
  defp async_stream_type?({{:., _dot, [aliased, :of]}, _call, [{:stream, _meta, [_item_type]}]}) do
    async_result_alias?(aliased)
  end

  defp async_stream_type?(_type), do: false

  @spec async_result_alias?(Macro.t()) :: boolean()
  defp async_result_alias?({:__aliases__, _meta, [:Musubi, :AsyncResult]}), do: true
  defp async_result_alias?(Musubi.AsyncResult), do: true
  defp async_result_alias?(_other), do: false

  @spec build_stream_definition(atom(), Macro.t(), keyword(), [String.t()]) :: stream_definition()
  defp build_stream_definition(name, item_type, opts, path) do
    item_key = Keyword.get(opts, :item_key, default_item_key_ast(name))
    limit = normalize_literal_opt(Keyword.get(opts, :limit))

    %{
      name: name,
      path: Enum.reverse(path),
      item_type: item_type,
      item_key: item_key,
      limit: limit,
      opts:
        opts
        |> Keyword.put_new(:item_key, item_key)
        |> Keyword.update(:limit, nil, &normalize_literal_opt/1)
    }
  end

  @spec validate_unique_stream_names!([stream_definition()]) :: [stream_definition()]
  defp validate_unique_stream_names!(streams) do
    duplicates =
      streams
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)

    case duplicates do
      [] ->
        streams

      [{name, _count} | _rest] ->
        raise CompileError,
          description: "duplicate stream declaration #{inspect(name)} in state block"
    end
  end
end
