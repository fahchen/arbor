defmodule Arbor.Store do
  @moduledoc "Compile-time DSL entrypoint for Arbor store modules."

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Arbor.DSL.Command, only: [command: 1, command: 2]
      import Arbor.DSL.State, only: [state: 1]
      import Arbor.DSL.Attr, only: [attr: 2, attr: 3]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)

      @before_compile Arbor.Plugin.Reflection
    end
  end
end
