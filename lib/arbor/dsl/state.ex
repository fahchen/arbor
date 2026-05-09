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
        import Arbor.DSL.State, only: [field: 2, field: 3]

        unquote(block)
      end
    end
  end

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
end
