defmodule Arbor.Store do
  @moduledoc """
  Compile-time DSL entrypoint and behaviour contract for Arbor store modules.

  Stores `use Arbor.Store` and implement `render/1`, `mount/1`,
  `handle_command/3`, optionally `handle_async/3` and `terminate/2`.
  `render/1` returns the resolved Elixir-shaped term; wire conversion happens
  separately via `Arbor.Wire.to_wire/1`.
  """

  alias Arbor.Socket

  @doc """
  Produces the resolved Elixir-shaped render output for the current store.

  The returned term is still in Arbor's Elixir form. The runtime converts it
  to wire form later with `Arbor.Wire.to_wire/1`.
  """
  @callback render(socket :: Socket.t()) :: term()

  @doc """
  Initializes a freshly-mounted store socket.
  """
  @callback mount(socket :: Socket.t()) :: {:ok, Socket.t()}

  @doc """
  Handles a declared command for the current store.
  """
  @callback handle_command(name :: atom(), payload :: map(), socket :: Socket.t()) ::
              {:noreply, Socket.t()} | {:reply, map(), Socket.t()}

  @doc """
  Handles an async result routed to the current store.
  """
  @callback handle_async(name :: atom(), result :: term(), socket :: Socket.t()) ::
              {:noreply, Socket.t()}

  @doc """
  Handles store teardown after the page runtime begins terminating.
  """
  @callback terminate(reason :: term(), socket :: Socket.t()) :: any()

  @optional_callbacks handle_async: 3, terminate: 2

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use TypedStructor
      @behaviour Arbor.Store

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
      Module.put_attribute(__MODULE__, :__arbor_kind__, :store)

      @after_verify {Arbor.Type, :verify_module!}

      @doc false
      @spec __arbor_runtime_module__() :: boolean()
      def __arbor_runtime_module__, do: false

      @doc false
      @spec __arbor_kind__() :: :store
      def __arbor_kind__, do: :store

      @doc false
      @spec terminate(term(), Arbor.Socket.t()) :: :ok
      def terminate(_reason, _socket), do: :ok

      defoverridable terminate: 2

      @before_compile Arbor.Plugin.Reflection
    end
  end
end
