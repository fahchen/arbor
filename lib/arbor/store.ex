defmodule Arbor.Store do
  @moduledoc "Compile-time DSL entrypoint for Arbor store modules."

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor

      import Arbor.DSL.Command, only: [command: 1, command: 2]
      import Arbor.DSL.State, only: [state: 1]
      import Arbor.DSL.Attr, only: [attr: 2, attr: 3]
      import Arbor.Child, only: [child: 2]

      # Note: `stream_async/3,4` is intentionally NOT imported here. The
      # `state do` DSL exposes `stream_async/2,3` for declaring async-wrapped
      # stream fields, and Elixir cannot disambiguate same-name imports by
      # argument count. Stores call the runtime form via the fully-qualified
      # `Arbor.Async.stream_async/3,4`.
      import Arbor.Async.Macros,
        only: [
          assign_async: 3,
          assign_async: 4,
          start_async: 3,
          start_async: 4,
          cancel_async: 2,
          cancel_async: 3
        ]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_command_payload_fields__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)

      @after_verify {Arbor.Type, :verify_module!}

      @doc false
      @spec __arbor_runtime_module__() :: boolean()
      def __arbor_runtime_module__, do: false

      @before_compile Arbor.Plugin.Reflection
    end
  end
end
