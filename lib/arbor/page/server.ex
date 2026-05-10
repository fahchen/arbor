defmodule Arbor.Page.Server do
  @moduledoc """
  Page-scoped Arbor runtime GenServer. Hosts the store tree for one connected
  client session and runs the command pipeline (routing → `:before_command`
  hooks → `handle_command/3` → `:after_command` hooks → reply) per
  BDR-0007/0009.

  ## Cross-track contract (M3 → M4)

  Transport adapters call `command/4` to dispatch a single client command.
  The runtime returns the channel reply payload — `{:ok, reply_payload}` —
  which the transport forwards to the client. Reply ordering matches
  BDR-0009: the reply is the call's return value; the patch push and effects
  fire after.
  """

  use GenServer

  require Logger

  alias Arbor.Hooks.ValidateCommandSchema
  alias Arbor.Lifecycle
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Reconciler
  alias Arbor.Resolver
  alias Arbor.Socket
  alias Arbor.Telemetry

  @type start_arg() :: {module(), map(), term()}
  @type command_path() :: [String.t()]
  @type command_payload() :: map()
  @type command_reply() :: map()

  @doc """
  Starts one page-scoped runtime for the given root store module.

  ## Examples

      Arbor.Page.Server.start_link({MyApp.RootStore, %{"page_id" => "home"}, %{transport_pid: self()}})
      #=> {:ok, pid}
  """
  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({root_module, _params, _transport_opts} = arg) when is_atom(root_module) do
    GenServer.start_link(__MODULE__, arg)
  end

  @doc """
  Dispatches a command to the addressed store node and returns the channel
  reply payload.

  This is the public entry point a transport adapter calls to execute one
  client command end-to-end. The pipeline:

    1. Route `path` to a mounted store via `Arbor.Page.StoreRegistry.path_lookup/2`.
    2. Run `:before_command` hooks root-first along the chain of sockets.
    3. Dispatch `handle_command/3` on the addressed store module.
    4. Run `:after_command` hooks root-first along the chain.
    5. Return `{:ok, reply_payload}`.

  Path or command-name resolution failures `raise` (BDR-0003 let-it-crash);
  the GenServer crashes and the supervisor/transport observe the exit.

  ## Examples

      Arbor.Page.Server.command(pid, ["filters"], :change_query, %{"query" => "shirt"})
      #=> {:ok, %{}}
  """
  @spec command(GenServer.server(), command_path(), atom(), command_payload()) ::
          {:ok, command_reply()}
  def command(server, path, command_name, payload)
      when is_list(path) and is_atom(command_name) and is_map(payload) do
    GenServer.call(server, {:command, path, command_name, payload})
  end

  @impl GenServer
  @spec init(start_arg()) :: {:ok, State.t()}
  def init({root_module, params, transport_opts}) do
    Process.flag(:trap_exit, true)

    transport_pid =
      if is_map(transport_opts), do: Map.get(transport_opts, :transport_pid), else: nil

    root_socket =
      %Socket{
        id: "",
        parent_path: [],
        module: root_module,
        assigns: %{},
        private: %{},
        transport_pid: transport_pid
      }
      |> Socket.assign(Map.new(params))
      |> attach_default_hooks()
      |> Reconciler.mount_store()

    store_registry =
      StoreRegistry.put(StoreRegistry.new(), [], root_module, root_socket.id, %Entry{
        socket: root_socket,
        module: root_module
      })

    {root_socket, store_registry} = run_render_cycle(root_socket, store_registry)

    {:ok,
     %State{
       root_module: root_module,
       root_socket: root_socket,
       store_registry: store_registry,
       version: 0,
       transport: transport_opts
     }}
  end

  @impl GenServer
  @spec handle_call(
          {:command, command_path(), atom(), command_payload()},
          GenServer.from(),
          State.t()
        ) ::
          {:reply, {:ok, command_reply()}, State.t()}
  def handle_call({:command, path, command_name, payload}, _from, %State{} = state) do
    base_meta = %{page_id: page_id(state), path: path, command: command_name}
    started_at = System.monotonic_time()
    Telemetry.emit([:arbor, :command, :start], %{system_time: System.system_time()}, base_meta)

    try do
      {pipeline_status, reply, next_state} =
        run_command_pipeline(path, command_name, payload, state)

      Telemetry.emit(
        [:arbor, :command, :stop],
        %{duration: System.monotonic_time() - started_at},
        Map.put(base_meta, :status, :ok)
      )

      if pipeline_status == :ok do
        # M4 owns the diff engine + envelope construction; M3 emits a skeleton
        # patch :stop event so downstream observers see the slot is occupied.
        Telemetry.emit([:arbor, :patch, :stop], %{count: 0}, base_meta)
      end

      {:reply, {:ok, reply}, next_state}
    rescue
      error ->
        Telemetry.emit(
          [:arbor, :command, :exception],
          %{duration: System.monotonic_time() - started_at},
          Map.merge(base_meta, %{
            kind: :error,
            reason: error,
            stacktrace: __STACKTRACE__
          })
        )

        reraise error, __STACKTRACE__
    end
  end

  @impl GenServer
  @spec handle_info({:EXIT, pid(), term()}, State.t()) :: {:stop, term(), State.t()}
  def handle_info({:EXIT, pid, reason}, %State{} = state) do
    Logger.error("page server linked process exited: #{inspect(pid)} reason=#{inspect(reason)}")
    {:stop, reason, state}
  end

  @impl GenServer
  @spec terminate(term(), State.t()) :: :ok
  def terminate(reason, %State{root_module: root_module, root_socket: root_socket}) do
    if function_exported?(root_module, :terminate, 2) do
      root_module.terminate(reason, root_socket)
    end

    Logger.error("page server terminating for #{inspect(root_module)} reason=#{inspect(reason)}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Command pipeline
  # ---------------------------------------------------------------------------

  @spec run_command_pipeline(command_path(), atom(), command_payload(), State.t()) ::
          {:ok | :halted, command_reply(), State.t()}
  defp run_command_pipeline(path, command_name, payload, %State{} = state) do
    addressed = lookup_or_raise!(state.store_registry, path)
    validate_command_declared!(addressed.module, command_name)

    chain = path_chain(path)
    state = stamp_command_target(state, chain, addressed.module)

    case run_hook_chain(:before_command, chain, [command_name, payload], state, true) do
      {:halt_reply, reply, state} ->
        state = clear_command_target(state, chain)
        {:halted, reply, state}

      {:halt, state} ->
        state = clear_command_target(state, chain)
        {:halted, %{}, state}

      {:cont, state} ->
        state = clear_command_target(state, chain)
        {reply, state} = dispatch_handler(path, command_name, payload, state)

        case run_hook_chain(:after_command, chain, [command_name, payload], state, false) do
          {:cont, state} -> {:ok, reply, state}
          {:halt, state} -> {:ok, reply, state}
        end
    end
  end

  @spec lookup_or_raise!(StoreRegistry.t(), command_path()) :: Entry.t()
  defp lookup_or_raise!(registry, path) do
    case StoreRegistry.path_lookup(registry, path) do
      %Entry{} = entry ->
        entry

      nil ->
        raise ArgumentError, "no store mounted at path #{inspect(path)}"
    end
  end

  @spec validate_command_declared!(module(), atom()) :: :ok
  defp validate_command_declared!(module, command_name) do
    commands =
      if function_exported?(module, :__arbor__, 1) do
        List.wrap(module.__arbor__(:commands))
      else
        []
      end

    if Enum.any?(commands, &(&1.name == command_name)) do
      :ok
    else
      raise ArgumentError,
            "command #{inspect(command_name)} not declared by #{inspect(module)}"
    end
  end

  # Walk path prefixes from root ([]) to the addressed full path so hooks
  # attached on ancestor sockets fire before hooks attached on descendants.
  @spec path_chain(command_path()) :: [command_path()]
  defp path_chain([]), do: [[]]

  defp path_chain(path) when is_list(path) do
    Enum.map(0..length(path), &Enum.take(path, &1))
  end

  @spec stamp_command_target(State.t(), [command_path()], module()) :: State.t()
  defp stamp_command_target(state, chain, target_module) do
    update_chain_sockets(state, chain, fn socket ->
      Socket.put_private(socket, ValidateCommandSchema.target_private_key(), target_module)
    end)
  end

  @spec clear_command_target(State.t(), [command_path()]) :: State.t()
  defp clear_command_target(state, chain) do
    key = ValidateCommandSchema.target_private_key()

    update_chain_sockets(state, chain, fn socket ->
      %{socket | private: Map.delete(socket.private, key)}
    end)
  end

  @spec update_chain_sockets(State.t(), [command_path()], (Socket.t() -> Socket.t())) :: State.t()
  defp update_chain_sockets(state, chain, fun) do
    Enum.reduce(chain, state, fn chain_path, acc ->
      case StoreRegistry.path_lookup(acc.store_registry, chain_path) do
        %Entry{socket: socket} = entry ->
          next_entry = %{entry | socket: fun.(socket)}
          put_entry(acc, chain_path, next_entry)

        nil ->
          acc
      end
    end)
  end

  @spec run_hook_chain(
          Lifecycle.stage(),
          [command_path()],
          [term()],
          State.t(),
          boolean()
        ) ::
          {:cont, State.t()} | {:halt, State.t()} | {:halt_reply, command_reply(), State.t()}
  defp run_hook_chain(stage, chain, hook_args, state, halt_payloads_allowed?) do
    Enum.reduce_while(chain, {:cont, state}, fn chain_path, {:cont, acc} ->
      run_hook_chain_step(chain_path, stage, hook_args, halt_payloads_allowed?, acc)
    end)
  end

  @spec run_hook_chain_step(
          command_path(),
          Lifecycle.stage(),
          [term()],
          boolean(),
          State.t()
        ) ::
          {:cont, {:cont, State.t()}}
          | {:halt, {:halt, State.t()}}
          | {:halt, {:halt_reply, command_reply(), State.t()}}
  defp run_hook_chain_step(chain_path, stage, hook_args, halt_payloads_allowed?, %State{} = acc) do
    case StoreRegistry.path_lookup(acc.store_registry, chain_path) do
      %Entry{socket: socket} = entry ->
        socket
        |> Lifecycle.run_hooks(stage, hook_args, halt_payloads_allowed?)
        |> wrap_hook_result(acc, chain_path, entry)

      nil ->
        {:cont, {:cont, acc}}
    end
  end

  @spec wrap_hook_result(Lifecycle.hook_result(), State.t(), command_path(), Entry.t()) ::
          {:cont, {:cont, State.t()}}
          | {:halt, {:halt, State.t()}}
          | {:halt, {:halt_reply, command_reply(), State.t()}}
  defp wrap_hook_result({:cont, %Socket{} = next_socket}, acc, chain_path, entry) do
    {:cont, {:cont, put_entry(acc, chain_path, %{entry | socket: next_socket})}}
  end

  defp wrap_hook_result({:halt, %Socket{} = next_socket}, acc, chain_path, entry) do
    {:halt, {:halt, put_entry(acc, chain_path, %{entry | socket: next_socket})}}
  end

  defp wrap_hook_result({:halt, reply, %Socket{} = next_socket}, acc, chain_path, entry) do
    {:halt, {:halt_reply, reply, put_entry(acc, chain_path, %{entry | socket: next_socket})}}
  end

  @spec dispatch_handler(command_path(), atom(), command_payload(), State.t()) ::
          {command_reply(), State.t()}
  defp dispatch_handler(path, command_name, payload, %State{} = state) do
    %Entry{socket: socket, module: module} =
      entry =
      lookup_or_raise!(state.store_registry, path)

    case module.handle_command(command_name, payload, socket) do
      {:noreply, %Socket{} = next_socket} ->
        {%{}, put_entry(state, path, %{entry | socket: next_socket})}

      {:reply, reply, %Socket{} = next_socket} when is_map(reply) ->
        {reply, put_entry(state, path, %{entry | socket: next_socket})}

      other ->
        raise ArgumentError,
              "bad return from #{inspect(module)}.handle_command/3: expected " <>
                "{:noreply, socket} or {:reply, payload, socket}, got #{inspect(other)}"
    end
  end

  @spec put_entry(State.t(), command_path(), Entry.t()) :: State.t()
  defp put_entry(%State{store_registry: registry} = state, path, %Entry{} = entry) do
    {parent_path, id} = entry_identity(entry)

    next_registry = StoreRegistry.put(registry, parent_path, entry.module, id, entry)

    next_root_socket =
      if path == [] do
        entry.socket
      else
        state.root_socket
      end

    %{state | store_registry: next_registry, root_socket: next_root_socket}
  end

  @spec entry_identity(Entry.t()) :: {[Socket.path_segment()], String.t()}
  defp entry_identity(%Entry{socket: %Socket{parent_path: parent_path, id: id}}) do
    {parent_path, id || ""}
  end

  # ---------------------------------------------------------------------------
  # Render cycle (extracted from `init/1` so the command pipeline can reuse it)
  # ---------------------------------------------------------------------------

  @spec run_render_cycle(Socket.t(), StoreRegistry.t()) :: {Socket.t(), StoreRegistry.t()}
  defp run_render_cycle(%Socket{} = root_socket, %StoreRegistry{} = registry) do
    started_at = System.monotonic_time()

    {:ok, _resolved_root, next_root_socket, next_registry} =
      Resolver.resolve(root_socket, registry)

    Telemetry.emit(
      [:arbor, :render, :stop],
      %{duration: System.monotonic_time() - started_at},
      %{module: root_socket.module}
    )

    {next_root_socket, next_registry}
  end

  @spec attach_default_hooks(Socket.t()) :: Socket.t()
  defp attach_default_hooks(%Socket{} = socket) do
    :arbor
    |> Application.get_env(:default_hooks, [])
    |> Enum.reduce(socket, fn {id, stage, fun}, acc ->
      Lifecycle.attach_hook(acc, id, stage, fun)
    end)
  end

  @spec page_id(State.t()) :: term()
  defp page_id(%State{root_socket: %Socket{assigns: assigns}}) do
    Map.get(assigns, :page_id) || Map.get(assigns, "page_id")
  end
end
