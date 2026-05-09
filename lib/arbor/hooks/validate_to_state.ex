defmodule Arbor.Hooks.ValidateToState do
  @moduledoc """
  Validates resolved `to_state/1` output against `state do` field reflection.

  Runtime mode is configured via `Application.get_env(:arbor, :validate_to_state, :raise)`.
  """

  alias Arbor.Socket

  @type validation_mode() :: :raise | :telemetry
  @type validation_error_reason() ::
          :extra_key
          | :function_ref
          | :invalid_shape
          | :missing_key
          | :type_mismatch
          | :unknown_module
  @type validation_error() :: %{
          path: String.t(),
          message: String.t(),
          reason: validation_error_reason()
        }
  @doc """
  Runs render-output validation as an `:after_to_state` lifecycle hook.

  ## Examples

      socket = %Arbor.Socket{module: MyApp.RootStore}
      Arbor.Hooks.ValidateToState.after_to_state(%{title: "Inbox"}, socket)
      #=> {:cont, socket}
  """
  @spec after_to_state(map(), Socket.t()) :: Arbor.Lifecycle.hook_result()
  def after_to_state(resolved_output, %Socket{module: store_module} = socket)
      when is_atom(store_module) and is_map(resolved_output) do
    mode = configured_mode()

    case validate(resolved_output, store_module) do
      :ok ->
        emit_stop(store_module)
        {:cont, socket}

      {:error, errors} ->
        emit_exception(store_module, errors)

        case mode do
          :raise -> raise ArgumentError, format_errors(store_module, errors)
          :telemetry -> {:cont, socket}
        end
    end
  end

  @doc """
  Validates a resolved render output map against `store_module`'s reflected state fields.

  ## Examples

      Arbor.Hooks.ValidateToState.validate(%{title: "Inbox"}, MyApp.RootStore)
      #=> :ok
  """
  @spec validate(map(), module()) :: :ok | {:error, [validation_error()]}
  def validate(resolved_output, store_module)
      when is_map(resolved_output) and is_atom(store_module) do
    errors =
      store_module
      |> fetch_fields()
      |> validate_fields(resolved_output, store_module, "$")

    case errors do
      [] -> :ok
      _errors -> {:error, errors}
    end
  end

  def validate(_resolved_output, store_module) when is_atom(store_module) do
    {:error,
     [
       %{
         path: "$",
         message: "expected resolved output to be a map",
         reason: :invalid_shape
       }
     ]}
  end

  defp fetch_fields(store_module) do
    if function_exported?(store_module, :__arbor__, 1) do
      store_module.__arbor__(:fields)
    else
      []
    end
  end

  defp validate_fields(fields, value, current_module, path)
       when is_list(fields) and is_map(value) do
    field_names = MapSet.new(Enum.map(fields, & &1.name))

    field_errors =
      Enum.flat_map(fields, fn %{name: name, type: type} ->
        field_path = child_path(path, name)

        case fetch_map_key(value, name) do
          {:ok, field_value} ->
            validate_value(field_value, type, current_module, field_path)

          :error ->
            [
              %{
                path: field_path,
                message: "missing required field #{inspect(name)}",
                reason: :missing_key
              }
            ]
        end
      end)

    extra_key_errors =
      value
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(field_names, normalize_key(&1)))
      |> Enum.map(fn key ->
        %{
          path: child_path(path, key),
          message: "unexpected field #{inspect(key)}",
          reason: :extra_key
        }
      end)

    field_errors ++ extra_key_errors
  end

  defp validate_fields(_fields, value, _current_module, path) do
    [
      %{
        path: path,
        message: "expected map, got: #{inspect(value)}",
        reason: :invalid_shape
      }
    ]
  end

  defp validate_value(value, _type_ast, _current_module, path) when is_function(value) do
    [
      %{
        path: path,
        message: "function references are not allowed in resolved render output",
        reason: :function_ref
      }
    ]
  end

  defp validate_value(value, {:|, _meta, [left, right]}, current_module, path) do
    left_errors = validate_value(value, left, current_module, path)

    case left_errors do
      [] ->
        []

      _errors ->
        right_errors = validate_value(value, right, current_module, path)
        if right_errors == [], do: [], else: left_errors ++ right_errors
    end
  end

  defp validate_value(value, {:list, _meta, [item_type]}, current_module, path)
       when is_list(value) do
    Enum.flat_map(Enum.with_index(value), fn {item, index} ->
      validate_value(item, item_type, current_module, "#{path}[#{index}]")
    end)
  end

  defp validate_value(value, {:list, _meta, [_item_type]}, _current_module, path) do
    [
      %{
        path: path,
        message: "expected list, got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_value(value, {:map, _meta, []}, _current_module, path) when is_map(value) do
    reject_function_values(value, path)
  end

  defp validate_value(value, {:map, _meta, []}, _current_module, path) do
    [
      %{
        path: path,
        message: "expected map, got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_value(value, {:%{}, _meta, pairs}, current_module, path) when is_map(value) do
    required_keys =
      MapSet.new(Enum.map(pairs, fn {key_ast, _type_ast} -> literal_value(key_ast) end))

    pair_errors =
      Enum.flat_map(pairs, fn {key_ast, type_ast} ->
        key = literal_value(key_ast)
        pair_path = child_path(path, key)

        case fetch_map_key(value, key) do
          {:ok, nested_value} ->
            validate_value(nested_value, type_ast, current_module, pair_path)

          :error ->
            [
              %{
                path: pair_path,
                message: "missing required field #{inspect(key)}",
                reason: :missing_key
              }
            ]
        end
      end)

    extra_key_errors =
      value
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(required_keys, normalize_key(&1)))
      |> Enum.map(fn key ->
        %{
          path: child_path(path, key),
          message: "unexpected field #{inspect(key)}",
          reason: :extra_key
        }
      end)

    pair_errors ++ extra_key_errors
  end

  defp validate_value(value, {:%{}, _meta, _pairs}, _current_module, path) do
    [
      %{
        path: path,
        message: "expected map, got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_value(
         value,
         {{:., _dot_meta, [alias_ast, :state]}, _call_meta, []},
         current_module,
         path
       ) do
    case resolve_module(alias_ast, current_module) do
      {:ok, nested_module} -> validate_nested_module(value, nested_module, path)
      :error -> unknown_module_error(path, alias_ast)
    end
  end

  defp validate_value(
         value,
         {{:., _dot_meta, [alias_ast, :t]}, _call_meta, []},
         current_module,
         path
       ) do
    case resolve_module(alias_ast, current_module) do
      {:ok, nested_module} -> validate_remote_t(value, nested_module, path)
      :error -> unknown_module_error(path, alias_ast)
    end
  end

  defp validate_value(value, {:integer, _meta, []}, _current_module, _path)
       when is_integer(value),
       do: []

  defp validate_value(value, {:integer, _meta, []}, _current_module, path) do
    [
      %{
        path: path,
        message: "expected integer(), got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_value(value, {:boolean, _meta, []}, _current_module, _path)
       when is_boolean(value),
       do: []

  defp validate_value(value, {:boolean, _meta, []}, _current_module, path) do
    [
      %{
        path: path,
        message: "expected boolean(), got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_value(nil, nil, _current_module, _path), do: []

  defp validate_value(value, nil, _current_module, path) do
    [
      %{
        path: path,
        message: "expected nil, got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_value(value, literal, _current_module, path) when is_atom(literal) do
    if value === literal, do: [], else: literal_type_error(path, value, literal)
  end

  defp validate_value(value, literal, _current_module, path) when is_binary(literal) do
    if value === literal, do: [], else: literal_type_error(path, value, literal)
  end

  defp validate_value(value, literal, _current_module, path) when is_integer(literal) do
    if value === literal, do: [], else: literal_type_error(path, value, literal)
  end

  defp validate_value(value, literal, _current_module, path) when is_float(literal) do
    if value === literal, do: [], else: literal_type_error(path, value, literal)
  end

  defp validate_value(value, type_ast, _current_module, path) do
    [
      %{
        path: path,
        message:
          "unsupported reflected type #{Macro.to_string(type_ast)} for value #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_nested_module(value, nested_module, path) when is_map(value) do
    validate_fields(fetch_fields(nested_module), value, nested_module, path)
  end

  defp validate_nested_module(value, _nested_module, path) do
    [
      %{
        path: path,
        message: "expected map, got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_remote_t(value, String, path) when is_binary(value) do
    reject_function_values(value, path)
  end

  defp validate_remote_t(value, String, path) do
    [
      %{
        path: path,
        message: "expected String.t(), got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp validate_remote_t(value, nested_module, path) do
    if function_exported?(nested_module, :__arbor__, 1) do
      validate_nested_module(value, nested_module, path)
    else
      [
        %{
          path: path,
          message: "unsupported remote type #{inspect(nested_module)}.t()",
          reason: :type_mismatch
        }
      ]
    end
  end

  defp reject_function_values(value, path) when is_map(value) do
    Enum.flat_map(value, fn {key, nested_value} ->
      validate_dynamic_value(nested_value, child_path(path, key))
    end)
  end

  defp reject_function_values(value, path) when is_list(value) do
    Enum.flat_map(Enum.with_index(value), fn {item, index} ->
      validate_dynamic_value(item, "#{path}[#{index}]")
    end)
  end

  defp reject_function_values(_value, _path), do: []

  defp validate_dynamic_value(value, path) when is_function(value) do
    [
      %{
        path: path,
        message: "function references are not allowed in resolved render output",
        reason: :function_ref
      }
    ]
  end

  defp validate_dynamic_value(value, path) when is_map(value),
    do: reject_function_values(value, path)

  defp validate_dynamic_value(value, path) when is_list(value),
    do: reject_function_values(value, path)

  defp validate_dynamic_value(_value, _path), do: []

  defp resolve_module({:__aliases__, _meta, parts}, current_module) do
    case Enum.find(candidate_modules(current_module, parts), :error, fn module ->
           Code.ensure_loaded?(module)
         end) do
      :error -> :error
      module -> {:ok, module}
    end
  end

  defp resolve_module(module, _current_module) when is_atom(module) do
    if Code.ensure_loaded?(module), do: {:ok, module}, else: :error
  end

  defp resolve_module(_other, _current_module), do: :error

  defp candidate_modules(current_module, parts) do
    namespace_parts =
      current_module
      |> Module.split()
      |> Enum.drop(-1)

    namespaced = namespaced_candidates(namespace_parts, parts)

    [existing_module(parts) | namespaced]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp namespaced_candidates([], _parts), do: []

  defp namespaced_candidates(namespace_parts, parts) do
    for count <- Enum.reverse(1..length(namespace_parts)),
        prefix = Enum.take(namespace_parts, count),
        module = existing_module(prefix ++ parts),
        not is_nil(module),
        do: module
  end

  defp literal_value({:%{}, _meta, _pairs} = literal_map), do: literal_map
  defp literal_value(value), do: value

  defp fetch_map_key(value, key) when is_map(value) and is_atom(key) do
    cond do
      Map.has_key?(value, key) -> {:ok, Map.fetch!(value, key)}
      Map.has_key?(value, Atom.to_string(key)) -> {:ok, Map.fetch!(value, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_map_key(value, key) when is_map(value) do
    cond do
      Map.has_key?(value, key) ->
        {:ok, Map.fetch!(value, key)}

      is_binary(key) and String.match?(key, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) ->
        atom_key = String.to_existing_atom(key)
        if Map.has_key?(value, atom_key), do: {:ok, Map.fetch!(value, atom_key)}, else: :error

      true ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key), do: existing_atom(key) || key

  defp normalize_key(key), do: key

  defp child_path("$", key), do: "$.#{path_key(key)}"
  defp child_path(path, key), do: "#{path}.#{path_key(key)}"

  defp path_key(key) when is_atom(key), do: Atom.to_string(key)
  defp path_key(key) when is_binary(key), do: key
  defp path_key(key), do: inspect(key)

  defp unknown_module_error(path, alias_ast) do
    [
      %{
        path: path,
        message: "could not resolve reflected type module #{Macro.to_string(alias_ast)}",
        reason: :unknown_module
      }
    ]
  end

  defp literal_type_error(path, value, literal) do
    [
      %{
        path: path,
        message: "expected literal #{inspect(literal)}, got: #{inspect(value)}",
        reason: :type_mismatch
      }
    ]
  end

  defp existing_module(parts) when is_list(parts) do
    parts
    |> Enum.join(".")
    |> then(&existing_atom("Elixir." <> &1))
  end

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp emit_stop(store_module) do
    :telemetry.execute(
      [:arbor, :validate, :stop],
      %{count: 1},
      %{store_module: store_module, errors: []}
    )
  end

  defp emit_exception(store_module, errors) do
    :telemetry.execute(
      [:arbor, :validate, :exception],
      %{count: 1},
      %{store_module: store_module, errors: errors}
    )
  end

  defp configured_mode, do: Application.get_env(:arbor, :validate_to_state, :raise)

  defp format_errors(store_module, errors) do
    details =
      Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
        "#{path}: #{message}"
      end)

    "render output validation failed for #{inspect(store_module)}: #{details}"
  end
end
