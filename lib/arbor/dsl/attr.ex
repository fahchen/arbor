defmodule Arbor.DSL.Attr do
  @moduledoc "Compile-time `attr` declarations for parent-supplied Arbor assigns."

  @no_default {:__arbor_no_default__, __MODULE__}

  @doc "Sentinel stored in attr metadata when no `default:` option was declared."
  @spec no_default() :: term()
  def no_default, do: @no_default

  @doc """
  Declares a parent-supplied assign and stores its reflection metadata.

  Imported by `Arbor.Store`; metadata accumulates onto the `:__arbor_attrs__`
  module attribute and is exposed via `__arbor__(:attrs)` by
  `Arbor.Plugin.Reflection`.
  """
  defmacro attr(name, type, opts \\ []) do
    required = Keyword.get(opts, :required, false)
    validate_required!(name, required)

    default =
      if Keyword.has_key?(opts, :default) do
        Keyword.fetch!(opts, :default)
      else
        @no_default
      end

    metadata =
      Macro.escape(%{
        name: name,
        type: type,
        required: required,
        default: default
      })

    quote do
      @__arbor_attrs__ unquote(metadata)
    end
  end

  defp validate_required!(name, required) when is_atom(name) and is_boolean(required), do: :ok

  defp validate_required!(name, required) do
    raise ArgumentError,
          "attr/3 expects an atom name and boolean :required option, got name=#{inspect(name)} required=#{inspect(required)}"
  end
end
