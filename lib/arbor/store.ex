defmodule Arbor.Store do
  @moduledoc """
  Compile-time DSL entrypoint, behaviour contract, and runtime facade for
  Arbor store modules.

  Stores `use Arbor.Store` and implement `init/1`, `render/1`,
  `update/2`, `handle_command/3`, `handle_async/3`, `handle_info/2`,
  and `terminate/2`. Root stores opt in with `use Arbor.Store, root: true`
  and may also implement `mount/2` to receive client mount params before
  `init/1` runs.

  `render/1` returns the resolved Elixir-shaped term; wire conversion happens
  separately via `Arbor.Wire.to_wire/1`.

  ## Runtime facade

  `use Arbor.Store` blanket-imports this module so every helper below is
  available bare inside a store's callbacks. Each helper is a `defdelegate`
  to the underlying implementation module (`Arbor.Socket`, `Arbor.Stream`,
  `Arbor.Lifecycle`, `Arbor.Child`, `Arbor.DSL.Render`) or a `defmacro`
  that lowers to a runtime call (the async lifecycle helpers).

  | Surface          | Helpers                                                                                            |
  | :--------------- | :------------------------------------------------------------------------------------------------- |
  | Socket           | `assign/2,3`, `assign_new/3`, `update/3`, `changed?/2`, `get_private/2,3`, `put_private/3`         |
  | Streams          | `stream/3,4`, `stream_configure/3`, `stream_insert/3,4`, `stream_delete/3`, `stream_delete_by_item_key/3` |
  | Lifecycle        | `attach_hook/4`, `detach_hook/3`                                                                   |
  | Async            | `assign_async/3,4`, `start_async/3,4`, `stream_async/3,4`, `cancel_async/2,3`                      |
  | Render builders  | `child/2`, `stream/1`, `async_stream/1`                                                            |

  The fully-qualified module forms remain available — the facade is purely
  additive — so `Arbor.Socket.assign(...)` keeps working alongside the bare
  `assign(...)` form preferred inside store modules.
  """

  alias Arbor.Async
  alias Arbor.Lifecycle
  alias Arbor.Socket
  alias Arbor.Stream

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
  @type rendered() ::
          nil
          | boolean()
          | number()
          | String.t()
          | atom()
          | [rendered()]
          | %{optional(String.t() | atom()) => rendered()}
  @type root_params() :: %{optional(String.t()) => value()}
  @type terminate_reason() :: :normal | :shutdown | {:shutdown, value()} | value()

  @doc """
  Mounts a root store with client-supplied params.

  Only modules declared with `use Arbor.Store, root: true` receive this
  callback. Child stores use `init/1`.
  """
  @callback mount(params :: root_params(), socket :: Socket.t()) :: {:ok, Socket.t()}

  @doc """
  Initializes a freshly-created store socket.
  """
  @callback init(socket :: Socket.t()) :: {:ok, Socket.t()}

  @doc """
  Initializes a freshly-mounted store socket.

  This callback is kept for compatibility with pre-session stores. Prefer
  `init/1` for child stores and `mount/2` for root-only client params.
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

  @optional_callbacks mount: 2,
                      init: 1,
                      mount: 1,
                      update: 2,
                      handle_async: 3,
                      handle_info: 2,
                      terminate: 2

  # ---------------------------------------------------------------------------
  # Socket helpers (defdelegate -> Arbor.Socket)
  # ---------------------------------------------------------------------------

  @doc "See `Arbor.Socket.assign/2`."
  defdelegate assign(socket, attrs), to: Socket

  @doc "See `Arbor.Socket.assign/3`."
  defdelegate assign(socket, key, value), to: Socket

  @doc "See `Arbor.Socket.assign_new/3`."
  defdelegate assign_new(socket, key, fun), to: Socket

  @doc "See `Arbor.Socket.update/3`."
  defdelegate update(socket, key, fun), to: Socket

  @doc "See `Arbor.Socket.changed?/2`."
  defdelegate changed?(socket, key), to: Socket

  @doc "See `Arbor.Socket.get_private/3`."
  defdelegate get_private(socket, key, default \\ nil), to: Socket

  @doc "See `Arbor.Socket.put_private/3`."
  defdelegate put_private(socket, key, value), to: Socket

  # ---------------------------------------------------------------------------
  # Stream helpers (defdelegate -> Arbor.Stream)
  # ---------------------------------------------------------------------------

  @doc "See `Arbor.Stream.stream/4`."
  defdelegate stream(socket, name, items, opts \\ []), to: Stream

  @doc "See `Arbor.Stream.stream_configure/3`."
  defdelegate stream_configure(socket, name, opts), to: Stream

  @doc "See `Arbor.Stream.stream_insert/4`."
  defdelegate stream_insert(socket, name, item, opts \\ []), to: Stream

  @doc "See `Arbor.Stream.stream_delete/3`."
  defdelegate stream_delete(socket, name, item), to: Stream

  @doc "See `Arbor.Stream.stream_delete_by_item_key/3`."
  defdelegate stream_delete_by_item_key(socket, name, item_key), to: Stream

  # ---------------------------------------------------------------------------
  # Lifecycle helpers (defdelegate -> Arbor.Lifecycle)
  # ---------------------------------------------------------------------------

  @doc "See `Arbor.Lifecycle.attach_hook/4`."
  defdelegate attach_hook(socket, name, stage, fun), to: Lifecycle

  @doc "See `Arbor.Lifecycle.detach_hook/3`."
  defdelegate detach_hook(socket, name, stage), to: Lifecycle

  # ---------------------------------------------------------------------------
  # Async helpers — defmacros that lint at compile time and lower to
  # `Arbor.Async.{assign,start,stream}_async/3,4`.
  # ---------------------------------------------------------------------------

  @doc "See `Arbor.Async.assign_async/3,4`."
  defmacro assign_async(socket, key_or_keys, fun) do
    __warn_on_socket_capture__(fun, :assign_async, __CALLER__)

    quote do
      Arbor.Async.assign_async(unquote(socket), unquote(key_or_keys), unquote(fun))
    end
  end

  defmacro assign_async(socket, key_or_keys, fun, opts) do
    __warn_on_socket_capture__(fun, :assign_async, __CALLER__)

    quote do
      Arbor.Async.assign_async(
        unquote(socket),
        unquote(key_or_keys),
        unquote(fun),
        unquote(opts)
      )
    end
  end

  @doc "See `Arbor.Async.start_async/3,4`."
  defmacro start_async(socket, name, fun) do
    __warn_on_socket_capture__(fun, :start_async, __CALLER__)

    quote do
      Arbor.Async.start_async(unquote(socket), unquote(name), unquote(fun))
    end
  end

  defmacro start_async(socket, name, fun, opts) do
    __warn_on_socket_capture__(fun, :start_async, __CALLER__)

    quote do
      Arbor.Async.start_async(unquote(socket), unquote(name), unquote(fun), unquote(opts))
    end
  end

  @doc "See `Arbor.Async.stream_async/3,4`."
  defmacro stream_async(socket, name, fun) do
    __warn_on_socket_capture__(fun, :stream_async, __CALLER__)

    quote do
      Arbor.Async.stream_async(unquote(socket), unquote(name), unquote(fun))
    end
  end

  defmacro stream_async(socket, name, fun, opts) do
    __warn_on_socket_capture__(fun, :stream_async, __CALLER__)

    quote do
      Arbor.Async.stream_async(unquote(socket), unquote(name), unquote(fun), unquote(opts))
    end
  end

  @doc "See `Arbor.Async.cancel_async/2,3`."
  defdelegate cancel_async(socket, target), to: Async
  defdelegate cancel_async(socket, target, reason), to: Async

  # ---------------------------------------------------------------------------
  # Render builders (defdelegate / defmacro -> Arbor.Child / Arbor.DSL.Render)
  # ---------------------------------------------------------------------------

  @doc "See `Arbor.Child.child/2`."
  defdelegate child(module, opts), to: Arbor.Child

  @doc "See `Arbor.DSL.Render.stream/1`. Render-time placeholder."
  defmacro stream(name) when is_atom(name) do
    quote do
      %Arbor.Stream.Placeholder{name: unquote(name)}
    end
  end

  @doc "See `Arbor.DSL.Render.async_stream/1`. Render-time placeholder."
  defmacro async_stream(name) when is_atom(name) do
    quote do
      %Arbor.Stream.AsyncPlaceholder{name: unquote(name)}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: socket-capture lint shared by the async macros above.
  # Lifted from `Arbor.Async.Macros` so the facade owns the warning.
  # ---------------------------------------------------------------------------

  @doc false
  @spec __warn_on_socket_capture__(Macro.t(), atom(), Macro.Env.t()) :: :ok
  def __warn_on_socket_capture__(fun_ast, fun_name, caller) do
    if __captures_socket__(fun_ast) do
      IO.warn(
        "#{fun_name}/3,4: the task fn captures `socket`. " <>
          "Capturing the socket inside an async fun frozen at call time risks data races; " <>
          "bind the values you need to local variables before the fn instead.",
        Macro.Env.stacktrace(caller)
      )
    end

    :ok
  end

  # Only walk literal `fn …` or `&…` captures so calls like
  # `start_async(socket, :foo, build_fn(socket))` —
  # where `socket` flows through a helper rather than being captured by the
  # task fun — don't trigger a false warning.
  @spec __captures_socket__(Macro.t()) :: boolean()
  defp __captures_socket__({:fn, _meta, _clauses} = ast), do: __walk_for_socket__(ast)
  defp __captures_socket__({:&, _meta, _args} = ast), do: __walk_for_socket__(ast)
  defp __captures_socket__(_other), do: false

  @spec __walk_for_socket__(Macro.t()) :: boolean()
  defp __walk_for_socket__(ast) do
    {_ast, captured?} =
      Macro.prewalk(ast, false, fn
        {:socket, _meta, ctx} = node, _acc when is_atom(ctx) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    captured?
  end

  @doc false
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    root? = Module.get_attribute(env.module, :__arbor_root__) || false

    if not root? and Module.defines?(env.module, {:mount, 2}, :def) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "mount/2 is only allowed on root Arbor stores; " <>
            "declare `use Arbor.Store, root: true` before defining it"
    end

    quote(do: :ok)
  end

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    root? = Keyword.get(opts, :root, false)

    quote bind_quoted: [root?: root?] do
      use TypedStructor
      @behaviour Arbor.Store

      # LV-style single-facade import: every runtime helper a store calls
      # (assign, stream, attach_hook, assign_async, child, …) flows through
      # `Arbor.Store`. The compile-time DSL macros stay filtered because they
      # are only valid in specific syntactic positions.
      import Arbor.Store
      import Arbor.DSL.Command, only: [command: 1, command: 2]
      import Arbor.DSL.State, only: [state: 1]
      import Arbor.DSL.Attr, only: [attr: 2, attr: 3]

      Module.register_attribute(__MODULE__, :__arbor_fields__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_command_payload_fields__, accumulate: true)
      Module.register_attribute(__MODULE__, :__arbor_command_reply__, accumulate: false)
      Module.register_attribute(__MODULE__, :__arbor_attrs__, accumulate: true)
      Module.put_attribute(__MODULE__, :__arbor_kind__, :store)
      Module.put_attribute(__MODULE__, :__arbor_root__, root?)

      @after_verify {Arbor.Type, :verify_module!}

      @doc false
      @spec __arbor_runtime_module__() :: boolean()
      def __arbor_runtime_module__, do: false

      @doc false
      @spec __arbor_kind__() :: :store
      def __arbor_kind__, do: :store

      if @__arbor_root__ do
        @impl Arbor.Store
        @doc false
        @spec mount(Arbor.Store.root_params(), Arbor.Socket.t()) :: {:ok, Arbor.Socket.t()}
        def mount(_params, socket) do
          {:ok, socket}
        end
      end

      @impl Arbor.Store
      @doc false
      @spec init(Arbor.Socket.t()) :: {:ok, Arbor.Socket.t()}
      def init(socket) do
        if function_exported?(__MODULE__, :mount, 1) do
          apply(__MODULE__, :mount, [socket])
        else
          {:ok, socket}
        end
      end

      @impl Arbor.Store
      @doc false
      @spec terminate(Arbor.Store.terminate_reason(), Arbor.Socket.t()) :: :ok
      def terminate(_reason, _socket), do: :ok

      if @__arbor_root__ do
        defoverridable mount: 2, init: 1, terminate: 2
      else
        defoverridable init: 1, terminate: 2
      end

      @before_compile Arbor.Store
      @before_compile Arbor.Plugin.Reflection
    end
  end
end
