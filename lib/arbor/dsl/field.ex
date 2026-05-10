defmodule Arbor.DSL.Field do
  @moduledoc false

  @doc """
  Declares a typed field inside `state do` or `input do` blocks.

  Wraps `TypedStructor.field/3` but preserves field opts as quoted AST.
  TypedStructor eagerly evaluates field opts by default; Arbor's stream-field
  metadata pipeline needs those opts to remain quoted, especially `:item_key`,
  so reflection can embed them back into compiled module code. See
  `Arbor.Plugin.StateField.stream_fields/1` for the AST handling of `:item_key`
  and `Arbor.Plugin.StateField.normalize_literal_opt/1` for the selective
  literal evaluation used by `:limit`.

  Do not remove `Macro.escape(opts)` without rewriting the stream metadata and
  reflection pipeline.

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        state do
          field :title, String.t()
        end
      end

      defmodule ExampleInput do
        use Arbor.Input

        input do
          field :name, String.t()
        end
      end
  """
  @spec field(atom(), Macro.t()) :: Macro.t()
  @spec field(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro field(name, type, opts \\ []) when is_atom(name) and is_list(opts) do
    validate_reserved!(name)

    quote do
      TypedStructor.field(
        unquote(name),
        unquote(type),
        unquote(Macro.escape(opts))
      )
    end
  end

  @doc false
  @spec validate_reserved!(atom()) :: :ok
  def validate_reserved!(name) when is_atom(name) do
    if reserved?(name) do
      raise ArgumentError,
            "field name #{inspect(name)} uses the reserved `__arbor_*` prefix; " <>
              "those keys are injected by the runtime (e.g. `__arbor_store_id__`)"
    end

    :ok
  end

  defp reserved?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("__arbor_")
  end
end
