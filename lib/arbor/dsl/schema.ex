defmodule Arbor.DSL.Schema do
  @moduledoc false

  @stream_opts_key :arbor_stream_opts

  @type field_entry() :: {atom(), Macro.t()}

  @doc false
  @spec type_from_block(Macro.t()) :: Macro.t()
  def type_from_block(block) do
    pairs =
      block
      |> expressions()
      |> Enum.map(&field_entry_from_expr!/1)

    {:%{}, [], pairs}
  end

  @doc false
  @spec stream_type(Macro.t(), keyword()) :: Macro.t()
  def stream_type(item_type, opts) when is_list(opts) do
    {:stream, [{@stream_opts_key, opts}], [item_type]}
  end

  @doc false
  @spec stream_opts(Macro.t()) :: keyword()
  def stream_opts({:stream, meta, [_item_type]}) when is_list(meta) do
    Keyword.get(meta, @stream_opts_key, [])
  end

  def stream_opts(_type_ast), do: []

  @spec expressions(Macro.t()) :: [Macro.t()]
  defp expressions({:__block__, _meta, expressions}), do: expressions
  defp expressions(expression), do: [expression]

  @spec field_entry_from_expr!(Macro.t()) :: field_entry()
  defp field_entry_from_expr!({:field, _meta, [name, [do: nested]]}) when is_atom(name) do
    {name, type_from_block(nested)}
  end

  defp field_entry_from_expr!({:field, _meta, [name, type]}) when is_atom(name) do
    {name, type}
  end

  defp field_entry_from_expr!({:field, _meta, [name, _type, opts]})
       when is_atom(name) and is_list(opts) do
    raise ArgumentError,
          "nested field #{inspect(name)} does not support field options; " <>
            "extract a named Arbor.State module when options are needed"
  end

  defp field_entry_from_expr!({:stream, _meta, [name, [do: nested]]}) when is_atom(name) do
    {name, stream_type(type_from_block(nested), [])}
  end

  defp field_entry_from_expr!({:stream, _meta, [name, opts, [do: nested]]})
       when is_atom(name) and is_list(opts) do
    {name, stream_type(type_from_block(nested), opts)}
  end

  defp field_entry_from_expr!({:stream, _meta, [name, item_type]}) when is_atom(name) do
    {name, stream_type(item_type, [])}
  end

  defp field_entry_from_expr!({:stream, _meta, [name, item_type, opts]})
       when is_atom(name) and is_list(opts) do
    {name, stream_type(item_type, opts)}
  end

  defp field_entry_from_expr!(other) do
    raise ArgumentError,
          "unsupported nested state declaration: #{Macro.to_string(other)}"
  end
end
