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
        plugin(Arbor.Plugin.TypeScript)

        import TypedStructor, except: [field: 2, field: 3]
        import Arbor.DSL.Field, only: [field: 2, field: 3]

        # Drop the facade's runtime `stream/3,4` and `stream_async/3,4` for
        # the `state do` block so they cannot collide with the field-declaration
        # macros below.
        import Arbor.Store, except: [stream: 3, stream: 4, stream_async: 3, stream_async: 4]

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
  defmacro stream(name, do: block) when is_atom(name) do
    type = Arbor.DSL.Schema.stream_type(Arbor.DSL.Schema.type_from_block(block), [])

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        []
      )
    end
  end

  defmacro stream(name, item_type) when is_atom(name) do
    type = Arbor.DSL.Schema.stream_type(item_type, [])

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        []
      )
    end
  end

  defmacro stream(name, opts, do: block) when is_atom(name) and is_list(opts) do
    type = Arbor.DSL.Schema.stream_type(Arbor.DSL.Schema.type_from_block(block), opts)

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        unquote(opts)
      )
    end
  end

  defmacro stream(name, item_type, opts) when is_atom(name) and is_list(opts) do
    type = Arbor.DSL.Schema.stream_type(item_type, opts)

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
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
  defmacro stream_async(name, do: block) when is_atom(name) do
    type = Arbor.DSL.Schema.async_stream_type(Arbor.DSL.Schema.type_from_block(block), [])

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        []
      )
    end
  end

  defmacro stream_async(name, item_type) when is_atom(name) do
    type = Arbor.DSL.Schema.async_stream_type(item_type, [])

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        []
      )
    end
  end

  defmacro stream_async(name, opts, do: block) when is_atom(name) and is_list(opts) do
    type = Arbor.DSL.Schema.async_stream_type(Arbor.DSL.Schema.type_from_block(block), opts)

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        unquote(opts)
      )
    end
  end

  defmacro stream_async(name, item_type, opts) when is_atom(name) and is_list(opts) do
    type = Arbor.DSL.Schema.async_stream_type(item_type, opts)

    quote do
      Arbor.DSL.Field.field(
        unquote(name),
        unquote(type),
        unquote(opts)
      )
    end
  end
end
