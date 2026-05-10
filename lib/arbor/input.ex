defmodule Arbor.Input do
  @moduledoc """
  Compile-time DSL entrypoint for Arbor input-object schemas.

  Input modules are pure data types used as command-payload field shapes.
  They are distinct from `Arbor.State` (render output) and `Arbor.Store`
  (mountable runtime nodes): no `mount/1`, no `to_state/1`, no commands, no
  streams, no child eligibility. Only typed fields and validation.

  Inputs participate in:

    * `Arbor.Wire` — auto-derived so input structs serialize like state.
    * `Arbor.Type.valid?/3` — `Module.t()` references to an input module
      recurse via `__arbor_validate_input__/1`.
    * `Arbor.Hooks.ValidateCommandSchema` — payload fields typed
      `MyInput.t()` validate by recursing into the input module.

  ## Examples

      defmodule UserInput do
        use Arbor.Input

        input do
          field :name, String.t()
          field :age, integer()
        end
      end
  """

  @doc """
  Sets up a module to declare a reusable Arbor input with `input do ... end`.

  ## Examples

      defmodule UserInput do
        use Arbor.Input

        input do
          field :name, String.t()
        end
      end
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Arbor.DSL.Input, only: [input: 1]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)
      Module.put_attribute(__MODULE__, :__arbor_kind__, :input)

      @after_verify {Arbor.Type, :verify_module!}

      @doc false
      @spec __arbor_runtime_module__() :: boolean()
      def __arbor_runtime_module__, do: true

      @doc false
      @spec __arbor_kind__() :: :input
      def __arbor_kind__, do: :input

      @before_compile Arbor.Plugin.Reflection
    end
  end

  @doc """
  Returns whether `module` is an Arbor input-object module.

  ## Examples

      iex> defmodule InputKindExample do
      ...>   use Arbor.Input
      ...>   input do
      ...>     field :name, String.t()
      ...>   end
      ...> end
      iex> Arbor.Input.input_module?(InputKindExample)
      true
      iex> Arbor.Input.input_module?(Arbor.Socket)
      false
  """
  @spec input_module?(module()) :: boolean()
  def input_module?(module) when is_atom(module) do
    function_exported?(module, :__arbor_kind__, 0) and module.__arbor_kind__() == :input
  end
end
