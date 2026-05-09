defmodule Arbor.DSL.State do
  @moduledoc false

  @doc """
  Defines a typed Arbor state block on a store or reusable state module.

  ## Examples

      defmodule ExampleState do
        use Arbor.State

        state do
          field :title, String.t()
        end
      end
  """
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
            stream_async: 2,
            stream_async: 3
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

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        state do
          field :title, String.t()
        end
      end
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

  @doc """
  Declares a top-level stream field inside `state do`.

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        state do
          stream :messages, MessageState.t(), limit: -100
        end
      end
  """
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

  @doc """
  Declares an async-wrapped stream field inside `state do`.

  ## Examples

      defmodule ExampleStore do
        use Arbor.Store

        state do
          stream_async :messages, MessageState.t(), limit: -100
        end
      end
  """
  @spec stream_async(atom(), Macro.t()) :: Macro.t()
  @spec stream_async(atom(), Macro.t(), keyword()) :: Macro.t()
  defmacro stream_async(name, item_type, opts \\ []) when is_atom(name) and is_list(opts) do
    quote do
      Arbor.DSL.State.field(
        unquote(name),
        Arbor.AsyncResult.of(stream(unquote(item_type))),
        unquote(opts)
      )
    end
  end
end
