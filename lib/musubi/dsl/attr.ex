defmodule Musubi.DSL.Attr do
  @moduledoc "Compile-time `attr` declarations for parent-supplied Musubi assigns."

  @no_default {:__musubi_no_default__, __MODULE__}

  @doc """
  Returns the sentinel stored in attr metadata when no `default:` option was declared.

  ## Examples

      iex> Musubi.DSL.Attr.no_default()
      {:__musubi_no_default__, Musubi.DSL.Attr}
  """
  @spec no_default() :: term()
  def no_default, do: @no_default

  @doc """
  Declares a parent-supplied assign and stores its reflection metadata.

  Imported by `Musubi.Store`; metadata accumulates onto the `:__musubi_attrs__`
  module attribute and is exposed via `__musubi__(:attrs)` by
  `Musubi.Plugin.Reflection`.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        attr :title, String.t(), required: true
      end
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
      @__musubi_attrs__ unquote(metadata)
    end
  end

  defp validate_required!(name, required) when is_atom(name) and is_boolean(required), do: :ok

  defp validate_required!(name, required) do
    raise ArgumentError,
          "attr/3 expects an atom name and boolean :required option, got name=#{inspect(name)} required=#{inspect(required)}"
  end
end
