# credo:disable-for-this-file
defmodule Arbor.DSL.Command do
  @moduledoc false

  @reserved_command_prefix "arbor:"

  @spec command(atom()) :: Macro.t()
  defmacro command(name) when is_atom(name) do
    validate_command_name!(name)

    quote bind_quoted: [name: name] do
      @__arbor_commands__ %{name: name, payload_fields: [], opts: []}
    end
  end

  @spec command(atom(), do: Macro.t()) :: Macro.t()
  defmacro command(name, do: block) when is_atom(name) do
    validate_command_name!(name)
    owner_module = __CALLER__.module

    # credo:disable-for-next-line
    generated_module =
      :"Elixir.#{owner_module}.ArborCommandPayload#{Macro.camelize(Atom.to_string(name))}"

    quote do
      typed_structor module: unquote(generated_module),
                     define_struct: false,
                     definer: Arbor.Plugin.Definer do
        plugin(Arbor.Plugin.CommandPayload,
          command_name: unquote(name),
          owner_module: unquote(owner_module)
        )

        import TypedStructor, only: [field: 2, field: 3]
        import Arbor.DSL.Command, only: [payload: 2, payload: 3]

        unquote(block)
      end
    end
  end

  @spec payload(atom(), Macro.t()) :: Macro.t()
  @spec payload(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro payload(name, type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote do
      TypedStructor.field(
        unquote(name),
        unquote(type),
        unquote(opts)
      )
    end
  end

  @spec validate_command_name!(atom()) :: :ok
  defp validate_command_name!(name) do
    if String.starts_with?(Atom.to_string(name), @reserved_command_prefix) do
      raise ArgumentError,
            "command names using the reserved #{@reserved_command_prefix} prefix are not allowed"
    end

    :ok
  end
end
