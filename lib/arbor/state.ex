defmodule Arbor.State do
  @moduledoc "Compile-time DSL entrypoint for Arbor reusable state modules."

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Arbor.DSL.State, only: [state: 1]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)
    end
  end
end
