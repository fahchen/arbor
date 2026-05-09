defmodule Arbor.Page.Server do
  @moduledoc "Page-scoped Arbor runtime GenServer. Hosts the store tree for one connected client session."

  use GenServer

  require Logger

  alias Arbor.Hooks.ValidateToState
  alias Arbor.Lifecycle
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Reconciler
  alias Arbor.Resolver
  alias Arbor.Socket
  alias Arbor.Telemetry

  @type start_arg :: {module(), map(), term()}

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
      |> Lifecycle.attach_hook(ValidateToState, :after_to_state, &ValidateToState.run/2)
      |> Reconciler.mount_store()

    store_registry =
      StoreRegistry.put(StoreRegistry.new(), [], root_module, root_socket.id, %Entry{
        socket: root_socket,
        module: root_module
      })

    render_started_at = System.monotonic_time()

    {:ok, _resolved_root, root_socket, store_registry} =
      Resolver.resolve(root_socket, store_registry)

    Telemetry.emit(
      [:arbor, :render, :stop],
      %{duration: System.monotonic_time() - render_started_at},
      %{module: root_module}
    )

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
end
