defmodule Arbor.DSL.State do
  @moduledoc false

  @spec state(do: Macro.t()) :: Macro.t()
  defmacro state(do: block) do
    quote do
      typed_structor definer: Arbor.Plugin.Definer do
        plugin(Arbor.Plugin.StateField)
        plugin(Arbor.Plugin.Reflection)
        plugin(Arbor.Plugin.TypeSpec)

        import TypedStructor, except: [field: 2, field: 3]

        import Arbor.DSL.State,
          only: [
            field: 2,
            field: 3,
            stream: 2,
            stream: 3,
            async_stream: 2,
            async_stream: 3
          ]

        unquote(block)
      end
    end
  end

  @doc """
  Wraps `TypedStructor.field/3` but preserves field opts as quoted AST.

  TypedStructor eagerly evaluates field opts by default. Arbor's stream-field
  metadata pipeline needs those opts to remain quoted, especially `:item_key`,
  so reflection can embed them back into compiled module code. See
  `Arbor.Plugin.StateField.stream_fields/1` for the AST handling of `:item_key`
  and `Arbor.Plugin.StateField.normalize_literal_opt/1` for the selective
  literal evaluation used by `:limit`.

  Do not remove `Macro.escape(opts)` without rewriting the stream metadata and
  reflection pipeline.
  """
  @spec field(atom(), Macro.t()) :: Macro.t()
  @spec field(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro field(name, type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote do
      TypedStructor.field(
        unquote(name),
        unquote(type),
        unquote(Macro.escape(opts))
      )
    end
  end

  @doc false
  @spec stream(atom(), Macro.t()) :: Macro.t()
  @spec stream(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro stream(name, item_type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote do
      Arbor.DSL.State.field(
        unquote(name),
        stream(unquote(item_type)),
        unquote(opts)
      )
    end
  end

  @doc false
  @spec async_stream(atom(), Macro.t()) :: Macro.t()
  @spec async_stream(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro async_stream(name, item_type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote do
      Arbor.DSL.State.field(
        unquote(name),
        Arbor.AsyncResult.of(stream(unquote(item_type))),
        unquote(opts)
      )
    end
  end
end
