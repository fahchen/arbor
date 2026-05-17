defmodule Musubi.DSL.Input do
  @moduledoc false

  @doc """
  Defines a typed Musubi input block on an input-object module.

  Input modules support only `field` declarations — no `stream`, no
  `command`, no `attr`. Auto-derives `Musubi.Wire` so input structs flow
  through the wire pipeline like `state do` modules.

  ## Examples

      defmodule UserInput do
        use Musubi.Input

        input do
          field :name, String.t()
          field :age, integer()
        end
      end
  """
  @spec input(do: Macro.t()) :: Macro.t()
  defmacro input(do: block) do
    quote do
      @derive Musubi.Wire

      typed_structor definer: Musubi.Plugin.Definer do
        plugin(Musubi.Plugin.StateField)
        plugin(Musubi.Plugin.Reflection)
        plugin(Musubi.Plugin.TypeSpec)

        import TypedStructor, except: [field: 2, field: 3]
        import Musubi.DSL.Field, only: [field: 2, field: 3]

        unquote(block)
      end
    end
  end
end
