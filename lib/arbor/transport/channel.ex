if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Arbor.Transport.Channel do
    @moduledoc """
    Generic Phoenix Channel adapter that mounts any Arbor root store named in
    the channel module's allowlist.

    The public client API connects to a root by `{module, id}` (see
    `docs/client-contract.md`). `topic` is an internal transport detail:
    the client builds an opaque topic of the form `"arbor:<opaque_ref>"` and
    carries the requested `module`, `id`, and optional `params` in the channel
    join payload.

    ## Mounting in a Phoenix endpoint

        defmodule MyAppWeb.ArborChannel do
          use Arbor.Transport.Channel,
            stores: [
              MyApp.Stores.CartPageStore,
              MyApp.Stores.InboxStore
            ]
        end

        defmodule MyAppWeb.UserSocket do
          use Phoenix.Socket

          channel "arbor:*", MyAppWeb.ArborChannel

          def connect(_params, socket, _connect_info), do: {:ok, socket}
          def id(_socket), do: nil
        end

    ## Join payload

    Incoming join payload:

        %{
          "module" => "MyApp.Stores.CartPageStore",
          "id" => "cart:current-user",
          "params" => %{...optional...}
        }

    The channel rejects joins whose `module` is not in the configured allowlist.

    ## Lifecycle

    On `join/3` the adapter starts a fresh `Arbor.Page.Server` for the resolved
    root module + params and links it to the channel pid. On channel
    `terminate/2` the adapter unlinks the page server and stops it with the
    channel's terminate reason. Reconnect is recovery (BDR-0015): each new
    join builds a fresh page server with `version: 1` and an initial
    `replace ""` envelope.

    ## Wire shape

    Incoming `"command"` payload:

        %{"store_id" => ["filters"], "name" => "change_query", "payload" => %{...}}

    `store_id` is the in-tree path-shaped locator for the addressed store node.
    Root is `[]`.

    Outgoing `"patch"` payload — `Arbor.Page.PatchEnvelope.to_wire/1`:

        %{
          "type" => "patch",
          "base_version" => 0,
          "version" => 1,
          "ops" => [...],
          "stream_ops" => [...]
        }

    ## Telemetry

      * `[:arbor, :channel, :join]` — `%{system_time: integer}`. Metadata:
        `module`, `id`, `topic`, `page_pid`.
      * `[:arbor, :channel, :terminate]` — `%{system_time: integer}`.
        Metadata: `module`, `id`, `topic`, `reason`, `page_pid`.
    """

    alias Arbor.Page.PatchEnvelope
    alias Arbor.Page.Server
    alias Arbor.Telemetry

    @doc false
    defmacro __using__(opts) do
      stores = Keyword.get(opts, :stores, [])

      quote bind_quoted: [stores: stores] do
        use Phoenix.Channel

        @__arbor_stores__ stores

        @doc false
        def __arbor_stores__, do: @__arbor_stores__

        @doc false
        @impl Phoenix.Channel
        def join(topic, params, socket) do
          Arbor.Transport.Channel.__join__(__MODULE__, topic, params, socket)
        end

        @doc false
        @impl Phoenix.Channel
        def handle_in("command", payload, socket) do
          Arbor.Transport.Channel.__handle_command__(payload, socket)
        end

        @doc false
        @impl Phoenix.Channel
        def handle_info({:patch, envelope}, socket) do
          Arbor.Transport.Channel.__handle_patch__(envelope, socket)
        end

        @doc false
        @impl Phoenix.Channel
        def terminate(reason, socket) do
          Arbor.Transport.Channel.__terminate__(reason, socket)
        end

        defoverridable join: 3, handle_in: 3, handle_info: 2, terminate: 2
      end
    end

    @doc false
    @spec __join__(module(), String.t(), map(), Phoenix.Socket.t()) ::
            {:ok, Phoenix.Socket.t()} | {:error, map()}
    def __join__(channel_module, topic, payload, %Phoenix.Socket{} = socket)
        when is_atom(channel_module) and is_binary(topic) and is_map(payload) do
      with {:ok, module_str} <- fetch_string(payload, "module"),
           {:ok, id} <- fetch_string(payload, "id"),
           {:ok, root_module} <- resolve_root(channel_module, module_str) do
        params = Map.get(payload, "params") || %{}
        join_params = Map.merge(params, %{"__arbor_root_id__" => id})

        {:ok, page_pid} =
          Server.start_link({root_module, join_params, %{transport_pid: self()}})

        Process.link(page_pid)

        Telemetry.emit(
          [:arbor, :channel, :join],
          %{system_time: System.system_time()},
          %{module: root_module, id: id, topic: topic, page_pid: page_pid}
        )

        {:ok,
         socket
         |> Phoenix.Socket.assign(:__arbor_page__, page_pid)
         |> Phoenix.Socket.assign(:__arbor_root__, root_module)
         |> Phoenix.Socket.assign(:__arbor_root_id__, id)
         |> Phoenix.Socket.assign(:__arbor_topic__, topic)}
      else
        {:error, reason} -> {:error, %{reason: reason}}
      end
    end

    @doc false
    @spec __handle_command__(map(), Phoenix.Socket.t()) ::
            {:reply, {:ok, map()}, Phoenix.Socket.t()}
    def __handle_command__(%{"name" => name} = payload, %Phoenix.Socket{} = socket)
        when is_binary(name) do
      page_pid = Map.fetch!(socket.assigns, :__arbor_page__)
      store_id = Map.get(payload, "store_id", [])
      command_payload = Map.get(payload, "payload", %{})

      command_name = String.to_existing_atom(name)

      {:ok, reply} = Server.command(page_pid, store_id, command_name, command_payload)

      {:reply, {:ok, reply}, socket}
    end

    @doc false
    @spec __handle_patch__(PatchEnvelope.t(), Phoenix.Socket.t()) ::
            {:noreply, Phoenix.Socket.t()}
    def __handle_patch__(%PatchEnvelope{} = envelope, %Phoenix.Socket{} = socket) do
      Phoenix.Channel.push(socket, "patch", PatchEnvelope.to_wire(envelope))
      {:noreply, socket}
    end

    @doc false
    @spec __terminate__(term(), Phoenix.Socket.t()) :: :ok
    def __terminate__(reason, %Phoenix.Socket{} = socket) do
      page_pid = Map.get(socket.assigns, :__arbor_page__)
      topic = Map.get(socket.assigns, :__arbor_topic__)
      root_module = Map.get(socket.assigns, :__arbor_root__)
      id = Map.get(socket.assigns, :__arbor_root_id__)

      Telemetry.emit(
        [:arbor, :channel, :terminate],
        %{system_time: System.system_time()},
        %{module: root_module, id: id, topic: topic, reason: reason, page_pid: page_pid}
      )

      if is_pid(page_pid) and Process.alive?(page_pid) do
        Process.unlink(page_pid)
        GenServer.stop(page_pid, reason, 1_000)
      end

      :ok
    end

    defp fetch_string(payload, key) do
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _other -> {:error, "missing #{key}"}
      end
    end

    defp resolve_root(channel_module, module_str) do
      allowlist = channel_module.__arbor_stores__()

      matched =
        Enum.find(allowlist, fn store ->
          store |> Module.split() |> Enum.join(".") == module_str
        end)

      cond do
        matched == nil ->
          {:error, "module #{inspect(module_str)} is not in the channel allowlist"}

        not Code.ensure_loaded?(matched) ->
          {:error, "module #{inspect(module_str)} is not loadable"}

        true ->
          {:ok, matched}
      end
    end
  end
end
