defmodule Musubi.Hooks.ValidateReplySchema do
  @moduledoc """
  Validates a command's reply against the addressed store's declared
  `reply_fields` schema.

  Attached to the `:after_command` lifecycle stage. The runtime stamps
  the addressed store module on each chain socket via the private key
  `Musubi.Hooks.ValidateCommandSchema.target_private_key/0` before the
  `:before_command` stage; that stamp remains in place across the
  handler and `:after_command` stages, so this hook reuses it.

  Validation walks each declared reply field, checks presence (string
  or atom key), and dispatches to `Musubi.Type.valid?/3`. Any mismatch
  raises `ArgumentError` per BDR-0003.

  Successful validation emits `[:musubi, :validate, :reply, :stop]`.

  ## Halt path

  Halts that short-circuit before `:after_command` (denial paths from
  `:before_command` and authz halts) bypass this hook entirely. Reply
  shapes returned via `{:halt, reply, socket}` from `:before_command`
  are NOT validated.
  """

  alias Musubi.Hooks.ValidateCommandSchema
  alias Musubi.Socket
  alias Musubi.Type

  @typedoc "Field-level validation error: `{field_name, message}`."
  @type validation_error() :: {atom(), String.t()}

  @doc """
  `:after_command` hook entrypoint. Validates `reply` against the
  declared `reply_fields` for `command_name` on the addressed store
  module.
  """
  @spec after_command(atom(), map(), map(), Socket.t()) :: Musubi.Lifecycle.hook_result()
  def after_command(command_name, _payload, reply, %Socket{} = socket)
      when is_atom(command_name) and is_map(reply) do
    target_module = target_module(socket)

    case command_spec(target_module, command_name) do
      :error ->
        {:cont, socket}

      {:ok, %{reply_fields: fields}} ->
        validate_fields!(target_module, command_name, fields, reply)
        emit_stop(target_module, command_name)
        {:cont, socket}
    end
  end

  @spec target_module(Socket.t()) :: module() | nil
  defp target_module(%Socket{} = socket) do
    Socket.get_private(socket, ValidateCommandSchema.target_private_key()) || socket.module
  end

  @spec command_spec(module() | nil, atom()) ::
          {:ok, %{name: atom(), reply_fields: list(), opts: keyword()}} | :error
  defp command_spec(nil, _command_name), do: :error

  defp command_spec(module, command_name) when is_atom(module) and is_atom(command_name) do
    if function_exported?(module, :__musubi__, 2) do
      module.__musubi__(:command, command_name)
    else
      :error
    end
  end

  @spec validate_fields!(module(), atom(), [map()], map()) :: :ok
  defp validate_fields!(module, command_name, fields, reply) do
    errors = Enum.reduce(fields, [], &collect_field_error(&1, reply, module, &2))

    case errors do
      [] ->
        :ok

      errors ->
        raise ArgumentError, format_errors(module, command_name, Enum.reverse(errors))
    end
  end

  @spec collect_field_error(map(), map(), module(), [validation_error()]) ::
          [validation_error()]
  defp collect_field_error(%{name: name, type: type_ast}, reply, module, acc) do
    case fetch_field(reply, name) do
      {:ok, value} ->
        if Type.valid?(value, type_ast, module) do
          acc
        else
          [{name, "expected #{Macro.to_string(type_ast)}, got: #{inspect(value)}"} | acc]
        end

      :error ->
        [{name, "missing required field"} | acc]
    end
  end

  @spec fetch_field(map(), atom()) :: {:ok, term()} | :error
  defp fetch_field(reply, name) when is_atom(name) do
    case Map.fetch(reply, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(reply, Atom.to_string(name))
    end
  end

  @spec format_errors(module(), atom(), [validation_error()]) :: String.t()
  defp format_errors(module, command_name, errors) do
    details =
      Enum.map_join(errors, "; ", fn {name, message} -> "#{name}: #{message}" end)

    "command reply validation failed for #{inspect(module)}.#{command_name}: #{details}"
  end

  @spec emit_stop(module(), atom()) :: :ok
  defp emit_stop(module, command_name) do
    Musubi.Telemetry.emit(
      [:musubi, :validate, :reply, :stop],
      %{count: 1},
      %{store_module: module, command: command_name}
    )
  end
end
