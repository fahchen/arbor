defmodule Arbor.DSL.Input do
  @moduledoc false

  @doc """
  Defines a typed Arbor input block on an input-object module.

  Input modules support only `field` declarations — no `stream`, no
  `command`, no `attr`. Auto-derives `Arbor.Wire` so input structs flow
  through the wire pipeline like `state do` modules.

  ## Examples

      defmodule UserInput do
        use Arbor.Input

        input do
          field :name, String.t()
          field :age, integer()
        end
      end
  """
  @spec input(do: Macro.t()) :: Macro.t()
  defmacro input(do: block) do
    quote do
      @derive Arbor.Wire

      typed_structor definer: Arbor.Plugin.Definer do
        plugin(Arbor.Plugin.StateField)
        plugin(Arbor.Plugin.Reflection)
        plugin(Arbor.Plugin.TypeSpec)

        import TypedStructor, except: [field: 2, field: 3]
        import Arbor.DSL.Field, only: [field: 2, field: 3]

        unquote(block)
      end
    end
  end
end
