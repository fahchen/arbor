defmodule Arbor.DSL.Command do
  @moduledoc false

  alias Arbor.Plugin.Normalize

  @reserved_command_prefix "arbor:"

  @doc """
  Declares a command with no payload fields.

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        command :refresh
      end
  """
  @spec command(atom()) :: Macro.t()
  defmacro command(name) when is_atom(name) do
    validate_command_name!(name)

    quote bind_quoted: [name: name] do
      @__arbor_commands__ %{name: name, payload_fields: [], opts: []}
    end
  end

  @doc """
  Declares a command whose payload is described inside the block.

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        command :rename do
          payload :title, String.t()
        end
      end
  """
  @spec command(atom(), do: Macro.t()) :: Macro.t()
  defmacro command(name, do: block) when is_atom(name) do
    validate_command_name!(name)

    quote do
      Module.delete_attribute(__MODULE__, :__arbor_command_payload_fields__)

      try do
        import Arbor.DSL.Command, only: [payload: 2, payload: 3]
        unquote(block)
      after
        :ok
      end

      payload_fields =
        __MODULE__
        |> Module.get_attribute(:__arbor_command_payload_fields__)
        |> List.wrap()
        |> Enum.reverse()
        |> Normalize.fields()

      Module.delete_attribute(__MODULE__, :__arbor_command_payload_fields__)

      @__arbor_commands__ %{name: unquote(name), payload_fields: payload_fields, opts: []}
    end
  end

  @doc """
  Declares one payload field inside a `command do ... end` block.

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        command :rename do
          payload :title, String.t()
        end
      end
  """
  @spec payload(atom(), Macro.t()) :: Macro.t()
  @spec payload(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro payload(name, type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote bind_quoted: [name: name, type: Macro.escape(type), opts: opts] do
      @__arbor_command_payload_fields__ Keyword.merge(opts, name: name, type: type)
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
