defmodule Arbor.State do
  @moduledoc "Compile-time DSL entrypoint for Arbor reusable state modules."

  @doc """
  Sets up a module to declare reusable Arbor state with `state do ... end`.

  ## Examples

      defmodule ExampleState do
        use Arbor.State

        state do
          field :title, String.t()
        end
      end
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Arbor.DSL.State, only: [state: 1]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)
      Module.put_attribute(__MODULE__, :__arbor_kind__, :state)

      @after_verify {Arbor.Type, :verify_module!}

      @doc false
      @spec __arbor_runtime_module__() :: boolean()
      def __arbor_runtime_module__, do: true

      @doc false
      @spec __arbor_kind__() :: :state
      def __arbor_kind__, do: :state

      @before_compile Arbor.Plugin.Reflection
    end
  end

  @doc """
  Returns whether `module` is an `Arbor.State` runtime-ineligible module.

  ## Examples

      iex> defmodule RuntimeStateExample do
      ...>   use Arbor.State
      ...>   state do
      ...>     field :title, String.t()
      ...>   end
      ...> end
      iex> Arbor.State.runtime_module?(RuntimeStateExample)
      true
      iex> Arbor.State.runtime_module?(Arbor.Socket)
      false
  """
  @spec runtime_module?(module()) :: boolean()
  def runtime_module?(module) when is_atom(module) do
    function_exported?(module, :__arbor_runtime_module__, 0) and module.__arbor_runtime_module__()
  end
end
