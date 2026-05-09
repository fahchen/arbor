defmodule Arbor.Page.Server do
  @moduledoc "Page-scoped Arbor runtime GenServer. Hosts the store tree for one connected client session."

  use GenServer

  require Logger

  alias Arbor.Hooks.ValidateToState
  alias Arbor.Lifecycle
  alias Arbor.Page.Server.State
  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Socket

  @type start_arg :: {module(), map(), term()}

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({root_module, _params, _transport_opts} = arg) when is_atom(root_module) do
    GenServer.start_link(__MODULE__, arg)
  end

  @impl GenServer
  @spec init(start_arg()) :: {:ok, State.t()}
  def init({root_module, _params, transport_opts}) do
    Process.flag(:trap_exit, true)

    root_socket =
      Lifecycle.attach_hook(
        %Socket{
          id: "",
          parent_path: [],
          module: root_module,
          assigns: %{},
          private: %{}
        },
        ValidateToState,
        :after_to_state,
        &ValidateToState.run/2
      )

    store_registry =
      StoreRegistry.put(StoreRegistry.new(), [], root_module, root_socket.id, %Entry{
        socket: root_socket,
        module: root_module
      })

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
  def terminate(reason, %State{root_module: root_module}) do
    Logger.error("page server terminating for #{inspect(root_module)} reason=#{inspect(reason)}")
    :ok
  end
end
