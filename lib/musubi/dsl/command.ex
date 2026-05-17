defmodule Musubi.DSL.Command do
  @moduledoc false

  alias Musubi.Plugin.Normalize

  @reserved_command_prefix "musubi:"

  @doc """
  Declares a command with no payload fields.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        command :refresh
      end
  """
  @spec command(atom()) :: Macro.t()
  defmacro command(name) when is_atom(name) do
    validate_command_name!(name)

    quote bind_quoted: [name: name] do
      @__musubi_commands__ %{name: name, payload_fields: [], reply: nil, opts: []}
    end
  end

  @doc """
  Declares a command whose payload (and optionally reply) is described inside
  the block.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        command :rename do
          payload :title, String.t()
          reply %{ok: boolean()}
        end
      end
  """
  @spec command(atom(), do: Macro.t()) :: Macro.t()
  defmacro command(name, do: block) when is_atom(name) do
    validate_command_name!(name)

    quote do
      Module.delete_attribute(__MODULE__, :__musubi_command_payload_fields__)
      Module.delete_attribute(__MODULE__, :__musubi_command_reply__)

      try do
        import Musubi.DSL.Command, only: [payload: 2, payload: 3, reply: 1]
        unquote(block)
      after
        :ok
      end

      payload_fields =
        __MODULE__
        |> Module.get_attribute(:__musubi_command_payload_fields__)
        |> List.wrap()
        |> Enum.reverse()
        |> Normalize.fields()

      reply_ast = Module.get_attribute(__MODULE__, :__musubi_command_reply__)

      Module.delete_attribute(__MODULE__, :__musubi_command_payload_fields__)
      Module.delete_attribute(__MODULE__, :__musubi_command_reply__)

      @__musubi_commands__ %{
        name: unquote(name),
        payload_fields: payload_fields,
        reply: reply_ast,
        opts: []
      }
    end
  end

  @doc """
  Declares one payload field inside a `command do ... end` block.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        command :rename do
          payload :title, String.t()
        end
      end
  """
  @spec payload(atom(), Macro.t()) :: Macro.t()
  @spec payload(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro payload(name, type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote bind_quoted: [name: name, type: Macro.escape(type), opts: opts] do
      @__musubi_command_payload_fields__ Keyword.merge(opts, name: name, type: type)
    end
  end

  @doc """
  Declares the reply type for a command inside a `command do ... end` block.

  The argument is a single Musubi type AST (the same shapes accepted by
  `field/2`), validated at compile time via `Musubi.Type.valid_type?/1`.
  Only one `reply` declaration per command is allowed; a later call raises.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        command :checkout do
          payload :coupon, String.t() | nil
          reply %{order_id: String.t()} | %{ok: false, reason: String.t()}
        end
      end
  """
  @spec reply(Macro.t()) :: Macro.t()
  defmacro reply(type_ast) do
    quote bind_quoted: [type_ast: Macro.escape(type_ast)] do
      unless Musubi.Type.valid_type?(type_ast) do
        raise CompileError,
          description:
            "Musubi #{inspect(__MODULE__)}: unsupported command reply type " <>
              Macro.to_string(type_ast) <> ". See `Musubi.Type` for the supported AST shapes."
      end

      if Module.get_attribute(__MODULE__, :__musubi_command_reply__) do
        raise CompileError,
          description: "Musubi #{inspect(__MODULE__)}: duplicate `reply` declaration in command"
      end

      Module.put_attribute(__MODULE__, :__musubi_command_reply__, type_ast)
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
