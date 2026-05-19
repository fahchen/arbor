defmodule Musubi.DSL.Command do
  @moduledoc false

  alias Musubi.Plugin.Normalize

  @reserved_command_prefix "musubi:"
  @allowed_field_opts [:doc]

  @doc """
  Declares a command with no payload or reply fields.

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
      @__musubi_commands__ %{name: name, payload_fields: [], reply_fields: [], opts: []}
    end
  end

  @doc """
  Declares a command whose payload and/or reply schema is described inside
  `payload do ... end` / `reply do ... end` sub-blocks.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        command :rename do
          payload do
            field :title, String.t()
            field :body, String.t() | nil, doc: "optional body"
          end

          reply do
            field :ok, boolean()
          end
        end
      end

  Both sub-blocks are optional. An empty `payload do end` is equivalent to
  omitting it. Field opts accept only `:doc`; any other key raises a
  compile-time error.
  """
  @spec command(atom(), do: Macro.t()) :: Macro.t()
  defmacro command(name, do: block) when is_atom(name) do
    validate_command_name!(name)

    quote do
      Module.delete_attribute(__MODULE__, :__musubi_command_payload_fields__)
      Module.delete_attribute(__MODULE__, :__musubi_command_reply_fields__)
      Module.delete_attribute(__MODULE__, :__musubi_command_field_target__)

      try do
        import Musubi.DSL.Command, only: [payload: 1, reply: 1, field: 2, field: 3]
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

      reply_fields =
        __MODULE__
        |> Module.get_attribute(:__musubi_command_reply_fields__)
        |> List.wrap()
        |> Enum.reverse()
        |> Normalize.fields()

      Module.delete_attribute(__MODULE__, :__musubi_command_payload_fields__)
      Module.delete_attribute(__MODULE__, :__musubi_command_reply_fields__)
      Module.delete_attribute(__MODULE__, :__musubi_command_field_target__)

      @__musubi_commands__ %{
        name: unquote(name),
        payload_fields: payload_fields,
        reply_fields: reply_fields,
        opts: []
      }
    end
  end

  @doc """
  Declares the payload schema for a command. Use inside `command :name do ... end`.

  ## Examples

      command :rename do
        payload do
          field :title, String.t()
        end
      end
  """
  @spec payload(do: Macro.t()) :: Macro.t()
  defmacro payload(do: block) do
    quote do
      Module.put_attribute(__MODULE__, :__musubi_command_field_target__, :payload)

      try do
        import Musubi.DSL.Command, only: [field: 2, field: 3]
        unquote(block)
      after
        Module.delete_attribute(__MODULE__, :__musubi_command_field_target__)
      end
    end
  end

  @doc """
  Declares the reply schema for a command. Use inside `command :name do ... end`.

  ## Examples

      command :checkout do
        reply do
          field :order_id, String.t()
        end
      end
  """
  @spec reply(do: Macro.t()) :: Macro.t()
  defmacro reply(do: block) do
    quote do
      Module.put_attribute(__MODULE__, :__musubi_command_field_target__, :reply)

      try do
        import Musubi.DSL.Command, only: [field: 2, field: 3]
        unquote(block)
      after
        Module.delete_attribute(__MODULE__, :__musubi_command_field_target__)
      end
    end
  end

  @doc """
  Declares a single field inside a `payload do ... end` or `reply do ... end`
  block. Supported opts: `:doc`.
  """
  @spec field(atom(), Macro.t()) :: Macro.t()
  @spec field(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro field(name, type, opts \\ []) when is_atom(name) and is_list(opts) do
    validate_field_opts!(opts)

    quote bind_quoted: [name: name, type: Macro.escape(type), opts: opts] do
      attr =
        case Module.get_attribute(__MODULE__, :__musubi_command_field_target__) do
          :payload ->
            :__musubi_command_payload_fields__

          :reply ->
            :__musubi_command_reply_fields__

          _other ->
            raise CompileError,
              description:
                "Musubi #{inspect(__MODULE__)}: `field` is only valid inside " <>
                  "`payload do ... end` or `reply do ... end` blocks"
        end

      Module.put_attribute(__MODULE__, attr, Keyword.merge(opts, name: name, type: type))
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

  @spec validate_field_opts!(keyword()) :: :ok
  defp validate_field_opts!(opts) do
    case Keyword.keys(opts) -- @allowed_field_opts do
      [] ->
        validate_doc_opt!(opts)

      extras ->
        raise CompileError,
          description:
            "unsupported command field opts: #{inspect(extras)}; only #{inspect(@allowed_field_opts)} are allowed"
    end
  end

  @spec validate_doc_opt!(keyword()) :: :ok
  defp validate_doc_opt!(opts) do
    case Keyword.fetch(opts, :doc) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        :ok

      {:ok, value} ->
        raise CompileError,
          description: "command field `:doc` must be a binary, got: #{inspect(value)}"
    end
  end
end
