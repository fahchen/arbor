defmodule Arbor.Codegen.TypeScript do
  @moduledoc """
  Single-file TypeScript codegen for every Arbor `state do` module exposed by
  the current Mix project.

  ## Output shape

  One file (`priv/codegen/ts/arbor.ts` by default) containing:

    * a top-level `AsyncResult<T>` generic (always emitted)
    * one `export namespace <Segment>` per Elixir module path segment, nested
      to mirror the Elixir module tree
    * one `export type <LastSegment>` per Arbor module, declared inside the
      innermost matching namespace
    * for `Arbor.Store` modules with declared `command`s, a sibling
      `export namespace <LastSegment> { export type Commands = ... }`

  ## Type-name convention

  The TS type name equals the Elixir module's last alias segment, with no
  added suffix. `MyApp.Stores.ProductPageStore` becomes type `ProductPageStore`
  inside `namespace MyApp.Stores`. Cross-module references write the full
  Elixir module path; TS namespace lookup resolves it from the call site.

  Collisions are physically impossible because the namespace tree mirrors the
  Elixir module tree: two distinct modules cannot share the same fully-
  qualified name. A defensive sanity check still raises on duplicate paths.

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
  Returns whether `module` is TypeScript-codegen-eligible: it must be an Arbor
  store/state module that opted into the `Arbor.Plugin.TypeScript` plugin.

  ## Examples

      iex> Arbor.Codegen.TypeScript.eligible?(Arbor.TestSupport.TypespecProbe)
      true
      iex> Arbor.Codegen.TypeScript.eligible?(Arbor.Socket)
      false
  """
  @spec eligible?(module()) :: boolean()
  def eligible?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :__arbor__, 1) and
      has_ts_attribute?(module)
  end

  @doc """
  Renders one TypeScript bundle covering every module in `modules`. Modules
  must be already-loaded Arbor `state do` modules (filter via `eligible?/1`
  upstream).

  Returns the rendered source string. Raises `ArgumentError` on a duplicate
  fully-qualified module name (defensive — real modules can't collide).

  ## Examples

      iex> rendered = Arbor.Codegen.TypeScript.render([Arbor.TestSupport.TypespecProbe])
      iex> String.contains?(rendered, "export namespace Arbor")
      true
      iex> String.contains?(rendered, "export type TypespecProbe = {")
      true
  """
  @spec render([module()]) :: String.t()
  def render(modules) when is_list(modules) do
    modules
    |> Enum.uniq()
    |> Enum.sort_by(&Module.split/1)
    |> validate_no_duplicates!()
    |> build_tree()
    |> emit_bundle()
  end

  defp validate_no_duplicates!(modules) do
    duplicates =
      modules
      |> Enum.frequencies_by(&Module.split/1)
      |> Enum.filter(fn {_path, count} -> count > 1 end)

    case duplicates do
      [] -> modules
      _list -> raise ArgumentError, "duplicate Arbor module paths: #{inspect(duplicates)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Module tree
  # ---------------------------------------------------------------------------
  #
  # Builds a nested `%{segment => {children_map, leaf_module_or_nil}}` tree.
  # `leaf_module` is non-nil at the node whose full path equals an Arbor
  # module; the node may also have children (a module's name being a prefix
  # of another module's path is fine — TS allows declaration merging between
  # `export type X` and `export namespace X`).
  defp build_tree(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      insert_module(acc, Module.split(module), module)
    end)
  end

  defp insert_module(tree, [last], module) do
    Map.update(tree, last, {%{}, module}, fn {children, _existing} ->
      {children, module}
    end)
  end

  defp insert_module(tree, [head | rest], module) do
    Map.update(tree, head, {insert_module(%{}, rest, module), nil}, fn {children, leaf} ->
      {insert_module(children, rest, module), leaf}
    end)
  end

  # ---------------------------------------------------------------------------
  # Emission
  # ---------------------------------------------------------------------------

  defp emit_bundle(tree) do
    body = emit_tree(tree, 0)

    iodata = [
      header(),
      "\n",
      async_result_decl(),
      "\n",
      body
    ]

    IO.iodata_to_binary(iodata)
  end

  defp header do
    "// Generated by `mix arbor.codegen.ts`. Do not edit by hand.\n"
  end

  defp async_result_decl do
    """
    export type #{@async_result_alias}<T> =
      | { status: "loading"; result: T | null; reason: null }
      | { status: "ok"; result: T; reason: null }
      | { status: "failed"; result: T | null; reason: unknown }
    """
  end

  defp emit_tree(tree, depth) do
    tree
    |> Enum.sort_by(fn {segment, _entry} -> segment end)
    |> Enum.map(&emit_node(&1, depth))
    |> Enum.intersperse("\n")
  end

  # Cases (segment may carry a leaf module, children namespaces, or both):
  #
  #   * leaf only, no commands           → `export type <seg> = {...}`
  #   * leaf only, has commands          → type decl + adjacent
  #                                        `export namespace <seg> { Commands }`
  #   * children only                    → `export namespace <seg> { children }`
  #   * leaf + children (decl merging)   → type decl + `export namespace <seg>
  #                                        { children + optional Commands }`
  defp emit_node({segment, {children, leaf_module}}, depth) do
    indent = String.duplicate("  ", depth)

    cond do
      leaf_module && map_size(children) == 0 ->
        emit_leaf(segment, leaf_module, indent, depth)

      leaf_module ->
        [
          render_state_decl_for_module(segment, leaf_module, indent),
          "\n",
          emit_namespace_block(segment, children, leaf_module, indent, depth)
        ]

      true ->
        emit_namespace_block(segment, children, nil, indent, depth)
    end
  end

  defp emit_leaf(segment, module, indent, depth) do
    state_decl = render_state_decl_for_module(segment, module, indent)
    commands = List.wrap(module.__arbor__(:commands))

    if commands == [] do
      state_decl
    else
      [
        state_decl,
        "\n",
        render_commands_namespace(segment, commands, indent, depth)
      ]
    end
  end

  defp emit_namespace_block(segment, children, leaf_module, indent, depth) do
    inner_depth = depth + 1
    inner_indent = String.duplicate("  ", inner_depth)
    children_body = emit_tree(children, inner_depth)

    commands_body =
      case leaf_module && List.wrap(leaf_module.__arbor__(:commands)) do
        list when is_list(list) and list != [] ->
          ["\n", render_commands_type(list, inner_indent)]

        _none ->
          []
      end

    [
      indent,
      "export namespace ",
      segment,
      " {\n",
      children_body,
      commands_body,
      indent,
      "}\n"
    ]
  end

  defp render_state_decl_for_module(segment, module, indent) do
    fields =
      module
      |> module_fields()
      |> resolve_field_aliases(module)

    render_state_decl(segment, fields, indent)
  end

  defp module_fields(module), do: List.wrap(module.__arbor__(:fields))

  # Pre-resolve every `{:__aliases__, _, parts}` node inside a module's field
  # types against the host module's parent namespaces so codegen can render
  # the full Elixir module path even when the user `alias`'d the reference.
  # Replaces alias nodes in-place with the resolved alias atom list.
  defp resolve_field_aliases(fields, host_module) do
    Enum.map(fields, fn field ->
      Map.update!(field, :type, &resolve_aliases(&1, host_module))
    end)
  end

  defp resolve_aliases(ast, host_module) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, parts} = node when is_list(parts) ->
        case resolve_alias_parts(parts, host_module) do
          {:ok, atom} ->
            {:__aliases__, meta, atom |> Module.split() |> Enum.map(&String.to_atom/1)}

          :error ->
            node
        end

      other ->
        other
    end)
  end

  defp resolve_alias_parts(parts, host_module) do
    host_parts = host_module |> Module.split() |> Enum.map(&String.to_atom/1)

    # Walk parents from most-specific to least-specific. Use
    # `Module.safe_concat/1` so we never mint a fresh atom for a module that
    # was never loaded — only existing atoms can match a real module.
    Enum.find_value(length(host_parts)..0//-1, :error, fn n ->
      try do
        candidate = Module.safe_concat(Enum.take(host_parts, n) ++ parts)

        if Code.ensure_loaded?(candidate), do: {:ok, candidate}, else: nil
      rescue
        ArgumentError -> nil
      end
    end)
  end

  defp render_state_decl(name, fields, indent) do
    field_lines =
      fields
      |> filter_renderable_fields()
      |> Enum.map(fn %{name: field_name, type: type_ast} ->
        "#{indent}  #{field_name}: #{render_type(type_ast)}"
      end)

    [
      indent,
      "export type ",
      name,
      " = {\n",
      Enum.join(field_lines, "\n"),
      "\n",
      indent,
      "}\n"
    ]
  end

  defp render_commands_namespace(name, commands, indent, _depth) do
    inner_indent = indent <> "  "

    [
      indent,
      "export namespace ",
      name,
      " {\n",
      render_commands_type(commands, inner_indent),
      indent,
      "}\n"
    ]
  end

  defp render_commands_type(commands, indent) do
    field_indent = indent <> "  "

    field_lines =
      Enum.map(commands, fn %{name: cmd_name, payload_fields: payload_fields} ->
        "#{field_indent}#{cmd_name}: #{render_command_payload(payload_fields)}"
      end)

    [
      indent,
      "export type Commands = {\n",
      Enum.join(field_lines, "\n"),
      "\n",
      indent,
      "}\n"
    ]
  end

  defp filter_renderable_fields(fields) do
    Enum.reject(fields, fn %{name: name} -> name in [:__streams__] end)
  end

  defp render_command_payload([]), do: "{}"

  defp render_command_payload(fields) do
    body =
      Enum.map_join(fields, "; ", fn %{name: name, type: type_ast} ->
        "#{name}: #{render_type(type_ast)}"
      end)

    "{ " <> body <> " }"
  end

  # ---------------------------------------------------------------------------
  # Type-AST → TypeScript rendering
  # ---------------------------------------------------------------------------

  @doc """
  Renders a single Arbor field-type AST node as TypeScript.

  ## Examples

      iex> Arbor.Codegen.TypeScript.render_type(quote(do: String.t()))
      "string"
      iex> Arbor.Codegen.TypeScript.render_type(quote(do: list(String.t())))
      "string[]"
      iex> Arbor.Codegen.TypeScript.render_type(quote(do: stream(String.t())))
      "string[]"
      iex> Arbor.Codegen.TypeScript.render_type(quote(do: String.t() | nil))
      "string | null"
  """
  @spec render_type(Macro.t()) :: String.t()
  def render_type(type_ast), do: do_render(type_ast)

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

  defp has_ts_attribute?(module) do
    case Keyword.get(module.__info__(:attributes), :__arbor_ts__) do
      nil -> false
      [] -> false
      _value -> true
    end
  end
end
