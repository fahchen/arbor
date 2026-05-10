defmodule Arbor.Page.Server do
  @moduledoc """
  Page-scoped Arbor runtime GenServer. Hosts the store tree for one connected
  client session and runs the command pipeline (routing → `:before_command`
  hooks → `handle_command/3` → `:after_command` hooks → reply) per
  BDR-0007/0009.

  ## Cross-track contract (M3 → M4 → M5)

  Transport adapters call `command/4` to dispatch a single client command. The
  runtime returns the channel reply payload — `{:ok, reply_payload}` — which
  the transport forwards to the client. After the reply is sent, the runtime
  renders the tree, computes a JSON Patch diff against the previously-rendered
  wire root, accumulates stream ops queued during the handler, builds an
  `Arbor.Page.PatchEnvelope`, and pushes it to the bound transport pid via a
  `{:patch, envelope}` message on `handle_continue/2` (so the reply lands
  first per BDR-0009).

  At mount, the same flow runs once with `previous_wire_root: nil` — the
  initial envelope replaces the entire root path (`""`) with the freshly
  rendered wire root and starts the version counter at 1.

  Idle render cycles (no diff ops, no stream ops) emit nothing per BDR-0018.
  Halted commands (a `:before_command` hook returned `{:halt, ...}`) skip the
  render cycle entirely — there is no state mutation to diff.
  """

  use GenServer

  require Logger

  alias Arbor.Async
  alias Arbor.Diff
  alias Arbor.Hooks.ValidateCommandSchema
  alias Arbor.Lifecycle
  alias Arbor.Page.PatchEnvelope
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Reconciler
  alias Arbor.Resolver
  alias Arbor.Socket
  alias Arbor.Stream
  alias Arbor.Telemetry

  @type start_arg() :: {module(), map(), term()}
  @type store_id() :: Socket.store_id()
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

    1. Route `store_id` to a mounted store via `Arbor.Page.StoreRegistry.get/2`.
    2. Run `:before_command` hooks root-first along the chain of sockets.
    3. Dispatch `handle_command/3` on the addressed store module.
    4. Run `:after_command` hooks root-first along the chain.
    5. Return `{:ok, reply_payload}`.
    6. Render → diff → push patch envelope (after the reply lands).

  store_id or command-name resolution failures `raise` (BDR-0003 let-it-crash);
  the GenServer crashes and the supervisor/transport observe the exit.

  ## Examples

      Arbor.Page.Server.command(pid, ["filters"], :change_query, %{"query" => "shirt"})
      #=> {:ok, %{}}
  """
  @spec command(GenServer.server(), store_id(), atom(), command_payload()) ::
          {:ok, command_reply()}
  def command(server, store_id, command_name, payload)
      when is_list(store_id) and is_atom(command_name) and is_map(payload) do
    GenServer.call(server, {:command, store_id, command_name, payload})
  end

  @impl GenServer
  @spec init(start_arg()) ::
          {:ok, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
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
      StoreRegistry.put(StoreRegistry.new(), [], %Entry{
        socket: root_socket,
        module: root_module
      })

    {root_socket, store_registry} = run_render_cycle(root_socket, store_registry)

    {wire_root, store_registry} = root_wire(store_registry, root_socket)
    {stream_ops, store_registry} = flush_all_stream_ops(store_registry)

    envelope = PatchEnvelope.initial(wire_root, stream_ops)

    state =
      rebuild_async_index(%State{
        root_module: root_module,
        root_socket: root_socket(store_registry, root_socket),
        store_registry: store_registry,
        version: 1,
        previous_wire_root: wire_root,
        transport: transport_opts
      })

    Telemetry.emit(
      [:arbor, :patch, :stop],
      %{count: length(envelope.ops), stream_count: length(envelope.stream_ops)},
      %{module: root_module, version: state.version}
    )

    {:ok, state, {:continue, {:push_patch, envelope}}}
  end

  @impl GenServer
  @spec handle_call(
          {:command, store_id(), atom(), command_payload()},
          GenServer.from(),
          State.t()
        ) ::
          {:reply, {:ok, command_reply()}, State.t(),
           {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  def handle_call({:command, store_id, command_name, payload}, _from, %State{} = state) do
    base_meta = %{page_id: page_id(state), store_id: store_id, command: command_name}
    started_at = System.monotonic_time()
    Telemetry.emit([:arbor, :command, :start], %{system_time: System.system_time()}, base_meta)

    try do
      {pipeline_status, reply, next_state, envelope} =
        run_command_with_render(store_id, command_name, payload, state)

      Telemetry.emit(
        [:arbor, :command, :stop],
        %{duration: System.monotonic_time() - started_at},
        Map.put(base_meta, :status, :ok)
      )

      if pipeline_status == :ok do
        Telemetry.emit(
          [:arbor, :patch, :stop],
          %{
            count: envelope_op_count(envelope),
            stream_count: envelope_stream_count(envelope)
          },
          Map.put(base_meta, :version, next_state.version)
        )
      end

      {:reply, {:ok, reply}, next_state, {:continue, {:push_patch, envelope}}}
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
  @spec handle_continue({:push_patch, PatchEnvelope.t() | nil}, State.t()) ::
          {:noreply, State.t()}
  def handle_continue({:push_patch, nil}, %State{} = state), do: {:noreply, state}

  def handle_continue({:push_patch, %PatchEnvelope{} = envelope}, %State{} = state) do
    case transport_pid(state) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        send(pid, {:patch, envelope})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({ref, {:arbor_async_result, name, kind, classified}}, %State{} = state)
      when is_reference(ref) do
    handle_async_result(ref, classified, {nil, name, kind}, state)
  end

  def handle_info({ref, classified}, %State{} = state) when is_reference(ref) do
    handle_async_result(ref, classified, nil, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    handle_async_down(ref, reason, state)
  end

  def handle_info({:arbor_async_timeout, ref}, %State{} = state) when is_reference(ref) do
    handle_async_timeout(ref, state)
  end

  def handle_info({:EXIT, pid, reason}, %State{} = state) do
    Logger.error("page server linked process exited: #{inspect(pid)} reason=#{inspect(reason)}")
    {:stop, reason, state}
  end

  # Catch-all dispatch path for application messages (typically Phoenix.PubSub
  # broadcasts the root store subscribed to inside `mount/1`). Runs the
  # `:handle_info` hook chain on the root socket, dispatches to the root
  # store's `handle_info/2` callback when present, and re-renders. PubSub is
  # not built in (BDR-0005), so the runtime emits `[:arbor, :pubsub, :receive]`
  # purely for observability.
  def handle_info(message, %State{} = state) do
    Telemetry.emit(
      [:arbor, :pubsub, :receive],
      %{system_time: System.system_time()},
      %{module: state.root_module, page_id: page_id(state)}
    )

    dispatch_root_handle_info(message, state)
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
  # Command pipeline + render
  # ---------------------------------------------------------------------------

  @spec run_command_with_render(store_id(), atom(), command_payload(), State.t()) ::
          {:ok | :halted, command_reply(), State.t(), PatchEnvelope.t() | nil}
  defp run_command_with_render(store_id, command_name, payload, %State{} = state) do
    {pipeline_status, reply, state} =
      run_command_pipeline(store_id, command_name, payload, state)

    case pipeline_status do
      :ok ->
        {next_state, envelope} = render_and_envelope(state)
        {:ok, reply, next_state, envelope}

      :halted ->
        {:halted, reply, state, nil}
    end
  end

  @spec render_and_envelope(State.t()) :: {State.t(), PatchEnvelope.t() | nil}
  defp render_and_envelope(%State{} = state) do
    {next_root_socket, next_registry} =
      run_render_cycle(state.root_socket, state.store_registry)

    {wire_root, next_registry} = root_wire(next_registry, next_root_socket)
    {stream_ops, next_registry} = flush_all_stream_ops(next_registry)

    diff_ops = Diff.diff(state.previous_wire_root, wire_root)

    envelope = PatchEnvelope.build(state.version, diff_ops, stream_ops)

    next_version = if envelope, do: envelope.version, else: state.version

    next_state =
      rebuild_async_index(%{
        state
        | root_socket: root_socket(next_registry, next_root_socket),
          store_registry: next_registry,
          version: next_version,
          previous_wire_root: wire_root
      })

    {next_state, envelope}
  end

  @spec run_command_pipeline(store_id(), atom(), command_payload(), State.t()) ::
          {:ok | :halted, command_reply(), State.t()}
  defp run_command_pipeline(store_id, command_name, payload, %State{} = state) do
    addressed = lookup_or_raise!(state.store_registry, store_id)
    validate_command_declared!(addressed.module, command_name)

    chain = store_id_chain(store_id)
    state = stamp_command_target(state, chain, addressed.module)

    case run_hook_chain(:before_command, chain, [command_name, payload], state, true) do
      {:halt_reply, reply, state} ->
        # BDR-0008: graceful denial path. Emit `[:arbor, :auth, :deny]` so
        # operators can observe authz hooks halting commands without raising.
        Telemetry.emit(
          [:arbor, :auth, :deny],
          %{system_time: System.system_time()},
          %{
            page_id: page_id(state),
            module: addressed.module,
            path: store_id,
            command: command_name,
            reply: reply
          }
        )

        state = clear_command_target(state, chain)
        {:halted, reply, state}

      {:halt, state} ->
        state = clear_command_target(state, chain)
        {:halted, %{}, state}

      {:cont, state} ->
        state = clear_command_target(state, chain)
        {reply, state} = dispatch_handler(store_id, command_name, payload, state)

        case run_hook_chain(:after_command, chain, [command_name, payload], state, false) do
          {:cont, state} -> {:ok, reply, state}
          {:halt, state} -> {:ok, reply, state}
        end
    end
  end

  @spec lookup_or_raise!(StoreRegistry.t(), store_id()) :: Entry.t()
  defp lookup_or_raise!(registry, store_id) do
    case StoreRegistry.get(registry, store_id) do
      %Entry{} = entry ->
        entry

      nil ->
        raise ArgumentError, "no store mounted at store_id #{inspect(store_id)}"
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

  # Walk store_id prefixes from root ([]) to the addressed full store_id so
  # hooks attached on ancestor sockets fire before hooks attached on
  # descendants.
  @spec store_id_chain(store_id()) :: [store_id()]
  defp store_id_chain([]), do: [[]]

  defp store_id_chain(store_id) when is_list(store_id) do
    Enum.map(0..length(store_id), &Enum.take(store_id, &1))
  end

  @spec stamp_command_target(State.t(), [store_id()], module()) :: State.t()
  defp stamp_command_target(state, chain, target_module) do
    update_chain_sockets(state, chain, fn socket ->
      Socket.put_private(socket, ValidateCommandSchema.target_private_key(), target_module)
    end)
  end

  @spec clear_command_target(State.t(), [store_id()]) :: State.t()
  defp clear_command_target(state, chain) do
    key = ValidateCommandSchema.target_private_key()

    update_chain_sockets(state, chain, fn socket ->
      %{socket | private: Map.delete(socket.private, key)}
    end)
  end

  @spec update_chain_sockets(State.t(), [store_id()], (Socket.t() -> Socket.t())) :: State.t()
  defp update_chain_sockets(state, chain, fun) do
    Enum.reduce(chain, state, fn chain_id, acc ->
      case StoreRegistry.get(acc.store_registry, chain_id) do
        %Entry{socket: socket} = entry ->
          next_entry = %{entry | socket: fun.(socket)}
          put_entry(acc, chain_id, next_entry)

        nil ->
          acc
      end
    end)
  end

  @spec run_hook_chain(
          Lifecycle.stage(),
          [store_id()],
          [term()],
          State.t(),
          boolean()
        ) ::
          {:cont, State.t()} | {:halt, State.t()} | {:halt_reply, command_reply(), State.t()}
  defp run_hook_chain(stage, chain, hook_args, state, halt_payloads_allowed?) do
    Enum.reduce_while(chain, {:cont, state}, fn chain_id, {:cont, acc} ->
      run_hook_chain_step(chain_id, stage, hook_args, halt_payloads_allowed?, acc)
    end)
  end

  @spec run_hook_chain_step(
          store_id(),
          Lifecycle.stage(),
          [term()],
          boolean(),
          State.t()
        ) ::
          {:cont, {:cont, State.t()}}
          | {:halt, {:halt, State.t()}}
          | {:halt, {:halt_reply, command_reply(), State.t()}}
  defp run_hook_chain_step(chain_id, stage, hook_args, halt_payloads_allowed?, %State{} = acc) do
    case StoreRegistry.get(acc.store_registry, chain_id) do
      %Entry{socket: socket} = entry ->
        socket
        |> Lifecycle.run_hooks(stage, hook_args, halt_payloads_allowed?)
        |> wrap_hook_result(acc, chain_id, entry)

      nil ->
        {:cont, {:cont, acc}}
    end
  end

  @spec wrap_hook_result(Lifecycle.hook_result(), State.t(), store_id(), Entry.t()) ::
          {:cont, {:cont, State.t()}}
          | {:halt, {:halt, State.t()}}
          | {:halt, {:halt_reply, command_reply(), State.t()}}
  defp wrap_hook_result({:cont, %Socket{} = next_socket}, acc, chain_id, entry) do
    {:cont, {:cont, put_entry(acc, chain_id, %{entry | socket: next_socket})}}
  end

  defp wrap_hook_result({:halt, %Socket{} = next_socket}, acc, chain_id, entry) do
    {:halt, {:halt, put_entry(acc, chain_id, %{entry | socket: next_socket})}}
  end

  defp wrap_hook_result({:halt, reply, %Socket{} = next_socket}, acc, chain_id, entry) do
    {:halt, {:halt_reply, reply, put_entry(acc, chain_id, %{entry | socket: next_socket})}}
  end

  @spec dispatch_root_handle_info(term(), State.t()) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp dispatch_root_handle_info(message, %State{} = state) do
    chain = [[]]

    case run_hook_chain(:handle_info, chain, [message], state, false) do
      {:halt, state} ->
        {:noreply, state, {:continue, {:push_patch, nil}}}

      {:cont, state} ->
        state = invoke_root_handle_info(message, state)
        {next_state, envelope} = render_and_envelope(state)
        {:noreply, next_state, {:continue, {:push_patch, envelope}}}
    end
  end

  @spec invoke_root_handle_info(term(), State.t()) :: State.t()
  defp invoke_root_handle_info(message, %State{root_module: root_module} = state) do
    if function_exported?(root_module, :handle_info, 2) do
      %Entry{socket: socket} = entry = lookup_or_raise!(state.store_registry, [])

      case root_module.handle_info(message, socket) do
        {:noreply, %Socket{} = next_socket} ->
          put_entry(state, [], %{entry | socket: next_socket})

        other ->
          raise ArgumentError,
                "bad return from #{inspect(root_module)}.handle_info/2: expected " <>
                  "{:noreply, socket}, got #{inspect(other)}"
      end
    else
      state
    end
  end

  @spec dispatch_handler(store_id(), atom(), command_payload(), State.t()) ::
          {command_reply(), State.t()}
  defp dispatch_handler(store_id, command_name, payload, %State{} = state) do
    %Entry{socket: socket, module: module} =
      entry =
      lookup_or_raise!(state.store_registry, store_id)

    case module.handle_command(command_name, payload, socket) do
      {:noreply, %Socket{} = next_socket} ->
        {%{}, put_entry(state, store_id, %{entry | socket: next_socket})}

      {:reply, reply, %Socket{} = next_socket} when is_map(reply) ->
        {reply, put_entry(state, store_id, %{entry | socket: next_socket})}

      other ->
        raise ArgumentError,
              "bad return from #{inspect(module)}.handle_command/3: expected " <>
                "{:noreply, socket} or {:reply, payload, socket}, got #{inspect(other)}"
    end
  end

  @spec put_entry(State.t(), store_id(), Entry.t()) :: State.t()
  defp put_entry(%State{store_registry: registry} = state, store_id, %Entry{} = entry) do
    next_registry = StoreRegistry.put(registry, store_id, entry)

    next_root_socket =
      if store_id == [] do
        entry.socket
      else
        state.root_socket
      end

    %{state | store_registry: next_registry, root_socket: next_root_socket}
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

  @spec root_wire(StoreRegistry.t(), Socket.t()) :: {term(), StoreRegistry.t()}
  defp root_wire(%StoreRegistry{} = registry, %Socket{}) do
    case StoreRegistry.get(registry, []) do
      %Entry{wire_state: wire_state} -> {wire_state, registry}
      nil -> {nil, registry}
    end
  end

  @spec root_socket(StoreRegistry.t(), Socket.t()) :: Socket.t()
  defp root_socket(%StoreRegistry{} = registry, %Socket{} = fallback) do
    case StoreRegistry.get(registry, []) do
      %Entry{socket: socket} -> socket
      nil -> fallback
    end
  end

  # Walks every entry in the registry and concatenates their pending stream
  # ops in entry-discovery order (root first, then descendants in registry-key
  # order), clearing the per-socket accumulators along the way. Pending ops
  # do not survive across handlers (see `streams/lifecycle`).
  @spec flush_all_stream_ops(StoreRegistry.t()) :: {[Stream.op()], StoreRegistry.t()}
  defp flush_all_stream_ops(%StoreRegistry{} = registry) do
    sorted_keys =
      registry
      |> StoreRegistry.keys()
      |> Enum.sort_by(&length/1)

    Enum.reduce(sorted_keys, {[], registry}, fn store_id, {ops_acc, reg_acc} ->
      flush_entry(reg_acc, store_id, ops_acc)
    end)
  end

  @spec flush_entry(StoreRegistry.t(), StoreRegistry.identity_key(), [Stream.op()]) ::
          {[Stream.op()], StoreRegistry.t()}
  defp flush_entry(%StoreRegistry{} = registry, store_id, ops_acc) do
    case StoreRegistry.get(registry, store_id) do
      %Entry{socket: socket} = entry ->
        {entry_ops, next_socket} = Stream.flush_pending_ops(socket)

        next_registry =
          StoreRegistry.put(registry, store_id, %{entry | socket: next_socket})

        {ops_acc ++ entry_ops, next_registry}

      nil ->
        {ops_acc, registry}
    end
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

  @spec transport_pid(State.t()) :: pid() | nil
  defp transport_pid(%State{transport: transport}) when is_map(transport) do
    Map.get(transport, :transport_pid)
  end

  defp transport_pid(_state), do: nil

  @spec envelope_op_count(PatchEnvelope.t() | nil) :: non_neg_integer()
  defp envelope_op_count(nil), do: 0
  defp envelope_op_count(%PatchEnvelope{ops: ops}), do: length(ops)

  @spec envelope_stream_count(PatchEnvelope.t() | nil) :: non_neg_integer()
  defp envelope_stream_count(nil), do: 0
  defp envelope_stream_count(%PatchEnvelope{stream_ops: ops}), do: length(ops)

  # ---------------------------------------------------------------------------
  # Async message routing
  # ---------------------------------------------------------------------------

  @typedoc "Discard hint plumbed alongside async messages so a stale-ref lazy_discard can still attribute to a `store_id`/`name`/`kind`."
  @type discard_meta() ::
          {store_id() | nil, Async.tracking_name() | nil, Async.kind() | nil} | nil

  @spec handle_async_result(reference(), term(), discard_meta(), State.t()) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp handle_async_result(ref, classified, discard_meta, %State{} = state) do
    case Map.fetch(state.async_index, ref) do
      {:ok, {store_id, name, kind}} ->
        # Demonitor + flush any pending :DOWN for this ref so it does not
        # also drive a failed write after the success path has run.
        Process.demonitor(ref, [:flush])
        process_async_result(store_id, name, kind, classified, state)

      :error ->
        emit_lazy_discard(state, enrich_discard_meta(discard_meta))
        {:noreply, state, {:continue, {:push_patch, nil}}}
    end
  end

  @spec handle_async_down(reference(), term(), State.t()) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp handle_async_down(ref, reason, %State{} = state) do
    case Map.fetch(state.async_index, ref) do
      {:ok, {store_id, name, kind}} ->
        process_async_down(store_id, name, kind, reason, state)

      :error ->
        # Either the matching {ref, result} already arrived (success path
        # demonitored + flushed) or the task was for a node that no longer
        # exists. Either way: silent.
        {:noreply, state, {:continue, {:push_patch, nil}}}
    end
  end

  @spec handle_async_timeout(reference(), State.t()) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp handle_async_timeout(ref, %State{} = state) do
    case Map.fetch(state.async_index, ref) do
      {:ok, {store_id, name, _kind}} ->
        process_async_timeout(store_id, name, state)

      :error ->
        {:noreply, state, {:continue, {:push_patch, nil}}}
    end
  end

  @spec process_async_result(
          store_id(),
          Async.tracking_name(),
          Async.kind(),
          term(),
          State.t()
        ) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp process_async_result(store_id, name, kind, classified, %State{} = state) do
    with %Entry{} = entry <- fetch_entry(state, store_id),
         {:ok, tracking_entry} <- Async.fetch_tracking(entry.socket, name) do
      next_state =
        apply_async_result_to_entry(state, store_id, entry, name, tracking_entry, classified)

      {next_state, envelope} = render_and_envelope(next_state)
      {:noreply, next_state, {:continue, {:push_patch, envelope}}}
    else
      _missing ->
        emit_lazy_discard(state, {store_id, name, kind})
        {:noreply, state, {:continue, {:push_patch, nil}}}
    end
  end

  defp apply_async_result_to_entry(
         state,
         store_id,
         entry,
         name,
         %{kind: :start} = tracking_entry,
         classified
       ) do
    emit_async_stop(entry.socket, name, tracking_entry.kind, classified)
    dispatch_handle_async(state, store_id, entry, entry.module, name, tracking_entry, classified)
  end

  defp apply_async_result_to_entry(state, store_id, entry, name, tracking_entry, classified) do
    emit_async_stop(entry.socket, name, tracking_entry.kind, classified)
    next_socket = Async.apply_task_result(entry.socket, name, tracking_entry, classified)
    put_entry_by_store_id(state, store_id, %{entry | socket: next_socket})
  end

  @spec process_async_down(store_id(), Async.tracking_name(), Async.kind(), term(), State.t()) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp process_async_down(store_id, name, _kind, reason, %State{} = state) do
    with %Entry{} = entry <- fetch_entry(state, store_id),
         {:ok, tracking_entry} <- Async.fetch_tracking(entry.socket, name) do
      next_state = apply_async_down_to_entry(state, store_id, entry, name, tracking_entry, reason)
      {next_state, envelope} = render_and_envelope(next_state)
      {:noreply, next_state, {:continue, {:push_patch, envelope}}}
    else
      _missing -> {:noreply, state, {:continue, {:push_patch, nil}}}
    end
  end

  defp apply_async_down_to_entry(state, store_id, entry, name, tracking_entry, reason) do
    classified = {:exit, tracking_entry.cancel_reason || reason}

    emit_async_stop(
      entry.socket,
      name,
      tracking_entry.kind,
      classified
    )

    case tracking_entry.kind do
      :start ->
        dispatch_handle_async(
          state,
          store_id,
          entry,
          entry.module,
          name,
          tracking_entry,
          classified
        )

      :assign ->
        next_socket = Async.apply_task_down(entry.socket, name, tracking_entry, reason)
        put_entry_by_store_id(state, store_id, %{entry | socket: next_socket})

      :stream ->
        next_socket = Async.apply_task_down(entry.socket, name, tracking_entry, reason)
        put_entry_by_store_id(state, store_id, %{entry | socket: next_socket})
    end
  end

  @spec process_async_timeout(store_id(), Async.tracking_name(), State.t()) ::
          {:noreply, State.t(), {:continue, {:push_patch, PatchEnvelope.t() | nil}}}
  defp process_async_timeout(store_id, name, %State{} = state) do
    with %Entry{} = entry <- fetch_entry(state, store_id),
         {next_socket, %{pid: pid}} <- Async.mark_timeout(entry.socket, name) do
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      next_state = put_entry_by_store_id(state, store_id, %{entry | socket: next_socket})
      # No envelope yet — the resulting :DOWN will run render.
      {:noreply, next_state, {:continue, {:push_patch, nil}}}
    else
      _missing -> {:noreply, state, {:continue, {:push_patch, nil}}}
    end
  end

  @spec dispatch_handle_async(
          State.t(),
          store_id(),
          Entry.t(),
          module(),
          Async.tracking_name(),
          Async.tracking_entry(),
          term()
        ) :: State.t()
  defp dispatch_handle_async(state, store_id, entry, module, name, tracking_entry, classified) do
    socket = Async.drop_tracking_only(entry.socket, name)
    cancel_tracked_timer(tracking_entry)

    delivered = unwrap_for_handle_async(classified)
    chain = store_id_chain(store_id)

    state = put_entry_by_store_id(state, store_id, %{entry | socket: socket})

    case run_hook_chain(:handle_async, chain, [name, delivered], state, false) do
      {:cont, state} ->
        invoke_handle_async(state, store_id, module, name, delivered)

      {:halt, state} ->
        state
    end
  end

  @spec invoke_handle_async(State.t(), store_id(), module(), Async.tracking_name(), term()) ::
          State.t()
  defp invoke_handle_async(state, store_id, module, name, delivered) do
    %Entry{socket: socket} = entry = fetch_entry(state, store_id)

    if function_exported?(module, :handle_async, 3) do
      try do
        case module.handle_async(name, delivered, socket) do
          {:noreply, %Socket{} = next_socket} ->
            put_entry_by_store_id(state, store_id, %{entry | socket: next_socket})

          other ->
            raise ArgumentError,
                  "bad return from #{inspect(module)}.handle_async/3: expected " <>
                    "{:noreply, socket}, got #{inspect(other)}"
        end
      rescue
        error ->
          # BDR-0020: handle_async/3 exceptions are caught; runtime survives.
          Arbor.Async.Telemetry.exception(socket, name, :start, :error, error, __STACKTRACE__)

          Logger.error(
            "handle_async/3 raised on #{inspect(module)} for #{inspect(name)}: " <>
              Exception.format(:error, error, __STACKTRACE__)
          )

          state
      end
    else
      state
    end
  end

  defp unwrap_for_handle_async({:ok, value}), do: {:ok, value}
  defp unwrap_for_handle_async({:exit, reason_class}), do: {:exit, reason_class}

  defp cancel_tracked_timer(%{timer_ref: nil}), do: :ok

  defp cancel_tracked_timer(%{timer_ref: ref}) when is_reference(ref) do
    _cancel = Process.cancel_timer(ref)
    :ok
  end

  @spec fetch_entry(State.t(), store_id()) :: Entry.t() | nil
  defp fetch_entry(%State{store_registry: registry}, store_id) when is_list(store_id) do
    StoreRegistry.get(registry, store_id)
  end

  @spec put_entry_by_store_id(State.t(), store_id(), Entry.t()) :: State.t()
  defp put_entry_by_store_id(%State{store_registry: registry} = state, store_id, %Entry{} = entry)
       when is_list(store_id) do
    next_registry = StoreRegistry.put(registry, store_id, entry)

    next_root_socket =
      if store_id == [] do
        entry.socket
      else
        state.root_socket
      end

    %{state | store_registry: next_registry, root_socket: next_root_socket}
  end

  @spec rebuild_async_index(State.t()) :: State.t()
  defp rebuild_async_index(%State{store_registry: registry} = state) do
    index =
      Enum.reduce(StoreRegistry.keys(registry), %{}, &collect_entry_refs(registry, &1, &2))

    %{state | async_index: index}
  end

  defp collect_entry_refs(registry, store_id, acc) do
    case StoreRegistry.get(registry, store_id) do
      %Entry{socket: socket} ->
        Enum.reduce(Async.tracking(socket), acc, &put_ref(&1, store_id, &2))

      nil ->
        acc
    end
  end

  defp put_ref({name, %{ref: ref, kind: kind}}, store_id, acc) do
    Map.put(acc, ref, {store_id, name, kind})
  end

  @spec emit_async_stop(Socket.t(), Async.tracking_name(), Async.kind(), term()) :: :ok
  defp emit_async_stop(socket, name, kind, classified) do
    status =
      case classified do
        {:ok, {:ok, _value}} -> :ok
        {:ok, {:ok, _value, _opts}} -> :ok
        _other -> :failed
      end

    Arbor.Async.Telemetry.stop(socket, name, kind, status)
  end

  @spec enrich_discard_meta(discard_meta()) :: discard_meta()
  defp enrich_discard_meta(nil), do: nil
  defp enrich_discard_meta({_store_id, _name, _kind} = meta), do: meta

  @spec emit_lazy_discard(State.t(), discard_meta()) :: :ok
  defp emit_lazy_discard(%State{} = state, discard_meta) do
    {store_id, name, kind} =
      case discard_meta do
        {sid, n, k} -> {sid, n, k}
        nil -> {nil, nil, nil}
      end

    Arbor.Async.Telemetry.lazy_discard(
      %{
        page_id: page_id(state),
        module: state.root_module,
        store_id: store_id
      },
      name,
      kind
    )
  end
end
