defmodule Musubi.State do
  @moduledoc "Compile-time DSL entrypoint for Musubi reusable state modules."

  @doc """
  Sets up a module to declare reusable Musubi state with `state do ... end`.

  ## Examples

      defmodule ExampleState do
        use Musubi.State

        state do
          field :title, String.t()
        end
      end
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Musubi.DSL.State, only: [state: 1]

      Module.register_attribute(__MODULE__, :__musubi_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__musubi_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__musubi_attrs__, accumulate: true)
      Module.put_attribute(__MODULE__, :__musubi_kind__, :state)

      @after_verify {Musubi.Type, :verify_module!}

      @doc false
      @spec __musubi_runtime_module__() :: boolean()
      def __musubi_runtime_module__, do: true

      @doc false
      @spec __musubi_kind__() :: :state
      def __musubi_kind__, do: :state

      @before_compile Musubi.Plugin.Reflection
    end
  end

  @doc """
  Returns whether `module` is an `Musubi.State` runtime-ineligible module.

  ## Examples

      iex> defmodule RuntimeStateExample do
      ...>   use Musubi.State
      ...>   state do
      ...>     field :title, String.t()
      ...>   end
      ...> end
      iex> Musubi.State.runtime_module?(RuntimeStateExample)
      true
      iex> Musubi.State.runtime_module?(Musubi.Socket)
      false
  """
  @spec runtime_module?(module()) :: boolean()
  def runtime_module?(module) when is_atom(module) do
    function_exported?(module, :__musubi_runtime_module__, 0) and
      module.__musubi_runtime_module__()
  end
end
