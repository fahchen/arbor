defmodule Arbor.State do
  @moduledoc "Compile-time DSL entrypoint for Arbor reusable state modules."

  @doc """
  Returns whether `module` is an `Arbor.State` runtime-ineligible module.

  ## Examples

      Arbor.State.runtime_module?(MyApp.MoneyState)
      #=> true

      Arbor.State.runtime_module?(MyApp.CartStore)
      #=> false
  """
  @spec runtime_module?(module()) :: boolean()
  def runtime_module?(module) when is_atom(module) do
    function_exported?(module, :__arbor_runtime_module__, 0) and module.__arbor_runtime_module__()
  end

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Arbor.DSL.State, only: [state: 1]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)

      @doc false
      @spec __arbor_runtime_module__() :: boolean()
      def __arbor_runtime_module__, do: true

      @before_compile Arbor.Plugin.Reflection
    end
  end
end
