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
      @derive Arbor.Wire

      typed_structor definer: Arbor.Plugin.Definer do
        plugin(Arbor.Plugin.StateField)
        plugin(Arbor.Plugin.Reflection)
        plugin(Arbor.Plugin.TypeSpec)

        import TypedStructor, except: [field: 2, field: 3]
        import Arbor.DSL.Field, only: [field: 2, field: 3]

        import Arbor.DSL.State,
          only: [
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
      Arbor.DSL.Field.field(
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
      Arbor.DSL.Field.field(
        unquote(name),
        Arbor.AsyncResult.of(stream(unquote(item_type))),
        unquote(opts)
      )
    end
  end
end
