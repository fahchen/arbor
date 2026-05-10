defmodule Arbor.Codegen.TypeScript.TypeRenderer do
  @moduledoc """
  Pure converter from a single Arbor field-type AST node to its TypeScript
  string form. Lives separately from `Arbor.Codegen.TypeScript` so the
  conversion table can be exercised one AST shape at a time, with no bundle
  assembly, manifest discovery, or alias-expansion concerns mixed in.

  All `{:__aliases__, _, parts}` nodes are expected to be already-fully-
  qualified — `Arbor.Codegen.TypeScript.Manifest` resolves consumer aliases
  at `@after_compile` time using the captured `Macro.Env` before serializing.

  ## Type mapping

  | Arbor field type AST            | TypeScript                              |
  | :------------------------------ | :-------------------------------------- |
  | `String.t()` / `binary()`       | `string`                                |
  | `integer()` / `float()`         | `number`                                |
  | `boolean()`                     | `boolean`                               |
  | `atom()`                        | `string` (atoms serialize as strings)   |
  | `:literal` (atom literal)       | `"literal"`                             |
  | `nil`                           | `null`                                  |
  | `map()`                         | `Record<string, unknown>`               |
  | `%{key: T}`                     | `{ key: T }` (literal-keyed map)        |
  | `list(T)` / `[T]`               | `T[]`                                   |
  | `stream(T)`                     | `T[]` (server forgets values)           |
  | `T \\| U`                       | `T \| U`                                |
  | `Module.t()` / `Module.state()` | full Elixir alias path                  |
  | `Arbor.AsyncResult.of(T)`       | `AsyncResult<T>`                        |
  """

  @async_result_alias "AsyncResult"

  @doc """
  Renders a single Arbor field-type AST node as TypeScript.

  ## Examples

      iex> Arbor.Codegen.TypeScript.TypeRenderer.render(quote(do: String.t()))
      "string"
      iex> Arbor.Codegen.TypeScript.TypeRenderer.render(quote(do: list(String.t())))
      "string[]"
      iex> Arbor.Codegen.TypeScript.TypeRenderer.render(quote(do: stream(String.t())))
      "string[]"
      iex> Arbor.Codegen.TypeScript.TypeRenderer.render(quote(do: String.t() | nil))
      "string | null"
  """
  @spec render(Macro.t()) :: String.t()
  def render(type_ast), do: do_render(type_ast)

  defp do_render({:|, _meta, [left, right]}) do
    do_render(left) <> " | " <> do_render(right)
  end

  defp do_render({:list, _meta, [inner]}), do: wrap_array(do_render(inner))
  defp do_render({:stream, _meta, [inner]}), do: wrap_array(do_render(inner))

  defp do_render({:map, _meta, []}), do: "Record<string, unknown>"

  defp do_render({:string, _meta, []}), do: "string"
  defp do_render({:binary, _meta, []}), do: "string"
  defp do_render({:integer, _meta, []}), do: "number"
  defp do_render({:float, _meta, []}), do: "number"
  defp do_render({:boolean, _meta, []}), do: "boolean"
  defp do_render({:atom, _meta, []}), do: "string"

  # `String.t()` shortcut — must precede the generic literal-map clause whose
  # 3-tuple shape would otherwise capture this AST with `pairs=[]`.
  defp do_render({{:., _dot, [{:__aliases__, _meta, [:String]}, :t]}, _call, []}), do: "string"

  # `Arbor.AsyncResult.of(T)` — resolves the inner T recursively.
  defp do_render({{:., _dot, [aliased, :of]}, _call, [inner]}) do
    if async_result_alias?(aliased) do
      "#{@async_result_alias}<#{do_render(inner)}>"
    else
      "unknown"
    end
  end

  # `Module.t()` / `Module.state()` — emit the full Elixir alias path. TS
  # namespace lookup resolves it from inside the call site's namespace.
  defp do_render({{:., _dot, [aliased, kind]}, _call, []}) when kind in [:t, :state] do
    full_alias_path(aliased)
  end

  defp do_render({:%{}, _meta, pairs}) when is_list(pairs) do
    body =
      Enum.map_join(pairs, "; ", fn {key, value} ->
        "#{render_key(key)}: #{do_render(value)}"
      end)

    "{ " <> body <> " }"
  end

  defp do_render(nil), do: "null"
  defp do_render(true), do: "true"
  defp do_render(false), do: "false"

  defp do_render(literal) when is_atom(literal), do: inspect(Atom.to_string(literal))
  defp do_render(literal) when is_binary(literal), do: inspect(literal)
  defp do_render(literal) when is_integer(literal), do: Integer.to_string(literal)
  defp do_render(literal) when is_float(literal), do: Float.to_string(literal)

  defp do_render(_other), do: "unknown"

  defp wrap_array(rendered) do
    if String.contains?(rendered, " | ") or String.contains?(rendered, " & ") do
      "Array<#{rendered}>"
    else
      rendered <> "[]"
    end
  end

  defp render_key(key) when is_atom(key), do: Atom.to_string(key)
  defp render_key(key) when is_binary(key), do: inspect(key)

  defp full_alias_path({:__aliases__, _meta, parts}) when is_list(parts) do
    Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp full_alias_path(module) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end

  defp async_result_alias?({:__aliases__, _meta, [:Arbor, :AsyncResult]}), do: true
  defp async_result_alias?(Arbor.AsyncResult), do: true
  defp async_result_alias?(_other), do: false
end
