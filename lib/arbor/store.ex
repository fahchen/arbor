defmodule Arbor.Store do
  @moduledoc """
  Compile-time DSL entrypoint and behaviour contract for Arbor store modules.

  Stores `use Arbor.Store` and implement `mount/1`, `render/1`,
  `update/2`, `handle_command/3`, `handle_async/3`, `handle_info/2`,
  and `terminate/2`.
  `render/1` returns the resolved Elixir-shaped term; wire conversion happens
  separately via `Arbor.Wire.to_wire/1`.
  """

  alias Arbor.Async
  alias Arbor.Resolver
  alias Arbor.Socket

  @type value() ::
          nil
          | boolean()
          | number()
          | String.t()
          | atom()
          | pid()
          | reference()
          | port()
          | tuple()
          | [value()]
          | %{optional(value()) => value()}

  @type assigns() :: %{optional(Socket.assign_key()) => value()}
  @type async_name() :: Async.name_arg()
  @type async_result() :: {:ok, value()} | {:exit, value()}
  @type command_name() :: atom()
  @type command_payload() :: %{optional(String.t() | atom()) => value()}
  @type command_reply() :: map()
  @type message() :: value()
  @type rendered() :: Resolver.resolved_value()
  @type terminate_reason() :: :normal | :shutdown | {:shutdown, value()} | value()

  @doc """
  Initializes a freshly-mounted store socket.
  """
  @callback mount(socket :: Socket.t()) :: {:ok, Socket.t()}

  @doc """
  Produces the resolved Elixir-shaped render output for the current store.

  The returned term is still in Arbor's Elixir form. The runtime converts it
  to wire form later with `Arbor.Wire.to_wire/1`.
  """
  @callback render(socket :: Socket.t()) :: rendered()

  @doc """
  Updates a mounted store socket from new parent-supplied assigns.
  """
  @callback update(assigns :: assigns(), socket :: Socket.t()) :: {:ok, Socket.t()}

  @doc """
  Handles a declared command for the current store.
  """
  @callback handle_command(
              name :: command_name(),
              payload :: command_payload(),
              socket :: Socket.t()
            ) ::
              {:noreply, Socket.t()} | {:reply, command_reply(), Socket.t()}

  @doc """
  Handles an async result routed to the current store.
  """
  @callback handle_async(
              name :: async_name(),
              async_fun_result :: async_result(),
              socket :: Socket.t()
            ) ::
              {:noreply, Socket.t()}

  @doc """
  Handles an in-process message routed to the current store.
  """
  @callback handle_info(message :: message(), socket :: Socket.t()) :: {:noreply, Socket.t()}

  @doc """
  Handles store teardown after the page runtime begins terminating.
  """
  @callback terminate(reason :: terminate_reason(), socket :: Socket.t()) :: :ok

  @optional_callbacks update: 2, handle_async: 3, handle_info: 2, terminate: 2

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
      Module.register_attribute(__MODULE__, :__arbor_command_reply__, accumulate: false)
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
      @spec terminate(Arbor.Store.terminate_reason(), Arbor.Socket.t()) :: :ok
      def terminate(_reason, _socket), do: :ok

      defoverridable terminate: 2

      @before_compile Arbor.Plugin.Reflection
    end
  end
end
