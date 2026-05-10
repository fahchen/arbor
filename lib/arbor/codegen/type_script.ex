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

  alias Arbor.Codegen.TypeScript.TypeRenderer

  @async_result_alias "AsyncResult"

  @typedoc """
  An entry produced by `Arbor.Codegen.TypeScript.Manifest.list/0` and
  consumed by `render/1`. Pre-loaded reflection data — `render/1` performs no
  module-callback lookups itself.
  """
  @type entry() :: {module(), %{fields: list(), commands: list()}}

  @doc """
  Renders one TypeScript bundle covering every `{module, data}` entry in
  `entries`.

  Returns the rendered source string. Raises `ArgumentError` on a duplicate
  fully-qualified module name (defensive — real modules can't collide).

  ## Examples

      iex> entry = {Arbor.TestSupport.TypespecProbe, %{
      ...>   fields: List.wrap(Arbor.TestSupport.TypespecProbe.__arbor__(:fields)),
      ...>   commands: List.wrap(Arbor.TestSupport.TypespecProbe.__arbor__(:commands))
      ...> }}
      iex> rendered = Arbor.Codegen.TypeScript.render([entry])
      iex> String.contains?(rendered, "export namespace Arbor")
      true
      iex> String.contains?(rendered, "export type TypespecProbe = {")
      true
  """
  @spec render([entry()]) :: String.t()
  def render(entries) when is_list(entries) do
    entries
    |> Enum.uniq_by(fn {module, _data} -> module end)
    |> Enum.sort_by(fn {module, _data} -> Module.split(module) end)
    |> validate_no_duplicates!()
    |> build_tree()
    |> emit_bundle()
  end

  defp validate_no_duplicates!(entries) do
    duplicates =
      entries
      |> Enum.frequencies_by(fn {module, _data} -> Module.split(module) end)
      |> Enum.filter(fn {_path, count} -> count > 1 end)

    case duplicates do
      [] -> entries
      _list -> raise ArgumentError, "duplicate Arbor module paths: #{inspect(duplicates)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Module tree
  # ---------------------------------------------------------------------------
  #
  # Builds a nested `%{segment => {children_map, leaf_entry_or_nil}}` tree.
  # `leaf_entry` is non-nil at the node whose full path equals an Arbor
  # module; the node may also have children (a module's name being a prefix
  # of another module's path is fine — TS allows declaration merging between
  # `export type X` and `export namespace X`).
  defp build_tree(entries) do
    Enum.reduce(entries, %{}, fn {module, _data} = entry, acc ->
      insert_entry(acc, Module.split(module), entry)
    end)
  end

  defp insert_entry(tree, [last], entry) do
    Map.update(tree, last, {%{}, entry}, fn {children, _existing} ->
      {children, entry}
    end)
  end

  defp insert_entry(tree, [head | rest], entry) do
    Map.update(tree, head, {insert_entry(%{}, rest, entry), nil}, fn {children, leaf} ->
      {insert_entry(children, rest, entry), leaf}
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
    "// Generated by `mix compile.arbor_ts`. Do not edit by hand.\n"
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

  # Cases (segment may carry a leaf entry, children namespaces, or both):
  #
  #   * leaf only, no commands           → `export type <seg> = {...}`
  #   * leaf only, has commands          → type decl + adjacent
  #                                        `export namespace <seg> { Commands }`
  #   * children only                    → `export namespace <seg> { children }`
  #   * leaf + children (decl merging)   → type decl + `export namespace <seg>
  #                                        { children + optional Commands }`
  defp emit_node({segment, {children, leaf_entry}}, depth) do
    indent = String.duplicate("  ", depth)

    cond do
      leaf_entry && map_size(children) == 0 ->
        emit_leaf(segment, leaf_entry, indent, depth)

      leaf_entry ->
        [
          render_state_decl_for_entry(segment, leaf_entry, indent),
          "\n",
          emit_namespace_block(segment, children, leaf_entry, indent, depth)
        ]

      true ->
        emit_namespace_block(segment, children, nil, indent, depth)
    end
  end

  defp emit_leaf(segment, {_module, %{commands: commands}} = entry, indent, depth) do
    state_decl = render_state_decl_for_entry(segment, entry, indent)

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

  defp emit_namespace_block(segment, children, leaf_entry, indent, depth) do
    inner_depth = depth + 1
    inner_indent = String.duplicate("  ", inner_depth)
    children_body = emit_tree(children, inner_depth)

    commands_body =
      case leaf_entry && elem(leaf_entry, 1).commands do
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

  defp render_state_decl_for_entry(segment, {_module, %{fields: fields}}, indent) do
    render_state_decl(segment, fields, indent)
  end

  defp render_state_decl(name, fields, indent) do
    field_lines =
      fields
      |> filter_renderable_fields()
      |> Enum.map(fn %{name: field_name, type: type_ast} ->
        "#{indent}  #{field_name}: #{TypeRenderer.render(type_ast)}"
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
        "#{name}: #{TypeRenderer.render(type_ast)}"
      end)

    "{ " <> body <> " }"
  end
end
