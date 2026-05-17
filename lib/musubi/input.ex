defmodule Musubi.Input do
  @moduledoc """
  Compile-time DSL entrypoint for Musubi input-object schemas.

  Input modules are pure data types used as command-payload field shapes.
  They are distinct from `Musubi.State` (render output) and `Musubi.Store`
  (mountable runtime nodes): no `mount/1`, no `render/1`, no commands, no
  streams, no child eligibility. Only typed fields and validation.

  Inputs participate in:

    * `Musubi.Wire` — auto-derived so input structs serialize like state.
    * `Musubi.Type.valid?/3` — `Module.t()` references to an input module
      recurse via `__musubi_validate_input__/1`.
    * `Musubi.Hooks.ValidateCommandSchema` — payload fields typed
      `MyInput.t()` validate by recursing into the input module.

  ## Examples

      defmodule UserInput do
        use Musubi.Input

        input do
          field :name, String.t()
          field :age, integer()
        end
      end
  """

  @doc """
  Sets up a module to declare a reusable Musubi input with `input do ... end`.

  ## Examples

      defmodule UserInput do
        use Musubi.Input

        input do
          field :name, String.t()
        end
      end
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Musubi.DSL.Input, only: [input: 1]

      Module.register_attribute(__MODULE__, :__musubi_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__musubi_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__musubi_attrs__, accumulate: true)
      Module.put_attribute(__MODULE__, :__musubi_kind__, :input)

      @after_verify {Musubi.Type, :verify_module!}

      @doc false
      @spec __musubi_runtime_module__() :: boolean()
      def __musubi_runtime_module__, do: true

      @doc false
      @spec __musubi_kind__() :: :input
      def __musubi_kind__, do: :input

      @before_compile Musubi.Plugin.Reflection
    end
  end

  @doc """
  Returns whether `module` is an Musubi input-object module.

  ## Examples

      iex> defmodule InputKindExample do
      ...>   use Musubi.Input
      ...>   input do
      ...>     field :name, String.t()
      ...>   end
      ...> end
      iex> Musubi.Input.input_module?(InputKindExample)
      true
      iex> Musubi.Input.input_module?(Musubi.Socket)
      false
  """
  @spec input_module?(module()) :: boolean()
  def input_module?(module) when is_atom(module) do
    function_exported?(module, :__musubi_kind__, 0) and module.__musubi_kind__() == :input
  end
end
