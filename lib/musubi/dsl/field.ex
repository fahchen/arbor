defmodule Musubi.DSL.Field do
  @moduledoc false

  @doc """
  Declares a typed field inside `state do` or `input do` blocks.

  Wraps `TypedStructor.field/3` but preserves field opts as quoted AST.
  TypedStructor eagerly evaluates field opts by default; Musubi's stream-field
  metadata pipeline needs those opts to remain quoted, especially `:item_key`,
  so reflection can embed them back into compiled module code. See
  `Musubi.Plugin.StateField.stream_fields/1` for the AST handling of `:item_key`
  and `Musubi.Plugin.StateField.normalize_literal_opt/1` for the selective
  literal evaluation used by `:limit`.

  Do not remove `Macro.escape(opts)` without rewriting the stream metadata and
  reflection pipeline.

  ## Examples

      defmodule ExampleStore do
        use Musubi.Store

        state do
          field :title, String.t()
          # Atom unions render as TypeScript string-literal unions; the
          # wire carries the string form ("p1", "draw", nil → null).
          field :winner, :p1 | :p2 | :draw | nil
        end
      end

      defmodule ExampleInput do
        use Musubi.Input

        input do
          field :name, String.t()
        end
      end
  """
  @spec field(atom(), Macro.t()) :: Macro.t()
  @spec field(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro field(name, do: block) when is_atom(name) do
    validate_reserved!(name)
    type = Musubi.DSL.Schema.type_from_block(block)

    quote do
      TypedStructor.field(
        unquote(name),
        unquote(type),
        []
      )
    end
  end

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
            "field name #{inspect(name)} uses the reserved `__musubi_*` prefix; " <>
              "those keys are injected by the runtime (e.g. `__musubi_store_id__`)"
    end

    :ok
  end

  defp reserved?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("__musubi_")
  end
end
