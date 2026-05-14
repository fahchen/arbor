if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Arbor.Transport.ConnectionChannel do
    @moduledoc """
    Phoenix Channel adapter for Arbor sockets with multiple root stores.

    The channel owns one joined Arbor socket and a dynamic set of root page
    servers. `join/3` runs the socket module's `Arbor.Socket.handle_join/2` once.
    Each client `"mount"` message starts one root store page server using the
    shared joined socket assigns and private connection context.

    ## Telemetry

      * `[:arbor, :channel, :join]` — `%{system_time: integer}`. Metadata:
        `module`, `id`, `topic`, `page_pid`. For this adapter `module` is the
        Arbor socket module, and `id`/`page_pid` are `nil` because roots mount
        later inside the joined connection.
      * `[:arbor, :channel, :terminate]` — `%{system_time: integer}`.
        Metadata: `module`, `id`, `topic`, `reason`, `page_pid`, `root_count`.
        `root_count` is the number of mounted root page servers the connection is
        stopping.
    """

    use Phoenix.Channel

    alias Arbor.Page.PatchEnvelope
    alias Arbor.Page.Server
    alias Arbor.Socket
    alias Arbor.Telemetry
    alias Arbor.Transport.Socket, as: TransportSocket

    # Phoenix socket assign containing the Arbor socket module.
    @socket_module_key :__arbor_socket_module__
    # Phoenix socket assign containing the joined Arbor socket context.
    @connection_socket_key :__arbor_connection_socket__
    # Phoenix socket assign containing mounted root runtime entries keyed by root id.
    @mounted_roots_key :__arbor_mounted_roots__
    # Phoenix socket assign containing the channel topic.
    @topic_key :__arbor_topic__

    @impl Phoenix.Channel
    @spec join(String.t(), map(), Phoenix.Socket.t()) ::
            {:ok, Phoenix.Socket.t()} | {:error, map()}
    def join(topic, params, %Phoenix.Socket{} = socket)
        when is_binary(topic) and is_map(params) do
      with {:ok, socket_module} <- fetch_socket_module(socket),
           {:ok, connect_socket} <- TransportSocket.fetch_connect_socket(socket),
           arbor_socket <- build_connection_socket(topic, connect_socket),
           {:ok, joined_socket} <- socket_module.handle_join(params, arbor_socket) do
        Telemetry.emit(
          [:arbor, :channel, :join],
          %{system_time: System.system_time()},
          %{module: socket_module, id: nil, topic: topic, page_pid: nil}
        )

        {:ok,
         socket
         |> Phoenix.Socket.assign(@socket_module_key, socket_module)
         |> Phoenix.Socket.assign(@connection_socket_key, joined_socket)
         |> Phoenix.Socket.assign(@mounted_roots_key, %{})
         |> Phoenix.Socket.assign(@topic_key, topic)}
      else
        :error -> {:error, %{reason: "unauthorized"}}
        {:error, reason} -> {:error, %{reason: error_reason(reason)}}
      end
    end

    @impl Phoenix.Channel
    @spec handle_in(String.t(), map(), Phoenix.Socket.t()) ::
            {:reply, {:ok, map()} | {:error, map()}, Phoenix.Socket.t()}
    def handle_in("mount", payload, %Phoenix.Socket{} = socket) when is_map(payload) do
      with {:ok, module_str} <- fetch_string(payload, "module"),
           {:ok, root_id} <- fetch_root_id(payload),
           {:ok, params} <- fetch_params(payload),
           :ok <- ensure_root_not_mounted(socket, root_id),
           {:ok, root_module} <- fetch_declared_root(socket, module_str),
           :ok <- ensure_root_store(root_module),
           {:ok, page_pid} <- start_root_page(root_module, root_id, params, socket) do
        root_entry = %{pid: page_pid, module: root_module}

        socket = update_mounted_roots(socket, &Map.put(&1, root_id, root_entry))

        {:reply, {:ok, %{"root_id" => root_id}}, socket}
      else
        {:error, reason} -> {:reply, {:error, %{reason: error_reason(reason)}}, socket}
      end
    end

    def handle_in("command", payload, %Phoenix.Socket{} = socket) when is_map(payload) do
      with {:ok, name} <- fetch_string(payload, "name"),
           {:ok, root_id} <- fetch_string(payload, "root_id"),
           {:ok, page_pid} <- fetch_root_pid(socket, root_id) do
        store_id = Map.get(payload, "store_id", [])
        command_payload = Map.get(payload, "payload", %{})
        command_name = String.to_existing_atom(name)

        {:ok, reply} = Server.command(page_pid, store_id, command_name, command_payload)

        {:reply, {:ok, reply}, socket}
      else
        {:error, reason} -> {:reply, {:error, %{reason: error_reason(reason)}}, socket}
      end
    end

    def handle_in("unmount", payload, %Phoenix.Socket{} = socket) when is_map(payload) do
      with {:ok, root_id} <- fetch_string(payload, "root_id"),
           {:ok, root_entry} <- fetch_root_entry(socket, root_id) do
        stop_root(root_entry.pid, {:shutdown, :unmounted})

        socket = update_mounted_roots(socket, &Map.delete(&1, root_id))

        {:reply, {:ok, %{}}, socket}
      else
        {:error, reason} -> {:reply, {:error, %{reason: error_reason(reason)}}, socket}
      end
    end

    @impl Phoenix.Channel
    @spec handle_info({:arbor_root_patch, String.t(), PatchEnvelope.t()}, Phoenix.Socket.t()) ::
            {:noreply, Phoenix.Socket.t()}
    def handle_info({:arbor_root_patch, root_id, %PatchEnvelope{} = envelope}, socket)
        when is_binary(root_id) do
      payload =
        envelope
        |> PatchEnvelope.to_wire()
        |> Map.put("root_id", root_id)

      Phoenix.Channel.push(socket, "patch", payload)

      {:noreply, socket}
    end

    @impl Phoenix.Channel
    @spec terminate(term(), Phoenix.Socket.t()) :: :ok
    def terminate(reason, %Phoenix.Socket{} = socket) do
      roots = mounted_roots(socket)
      topic = Map.get(socket.assigns, @topic_key)
      socket_module = Map.get(socket.assigns, @socket_module_key)

      Telemetry.emit(
        [:arbor, :channel, :terminate],
        %{system_time: System.system_time()},
        %{
          module: socket_module,
          id: nil,
          topic: topic,
          reason: reason,
          page_pid: nil,
          root_count: map_size(roots)
        }
      )

      Enum.each(roots, fn {_root_id, root_entry} ->
        stop_root(root_entry.pid, reason)
      end)

      :ok
    end

    @spec fetch_socket_module(Phoenix.Socket.t()) :: {:ok, module()} | {:error, :missing_socket}
    defp fetch_socket_module(%Phoenix.Socket{handler: handler}) when is_atom(handler) do
      if function_exported?(handler, :__arbor_roots__, 0) do
        {:ok, handler}
      else
        {:error, :missing_socket}
      end
    end

    @spec build_connection_socket(String.t(), Socket.t()) :: Socket.t()
    defp build_connection_socket(topic, %Socket{} = connect_socket) when is_binary(topic) do
      %{connect_socket | topic: topic, transport_pid: self()}
    end

    @spec fetch_root_id(map()) :: {:ok, String.t()} | {:error, :missing_root_id}
    defp fetch_root_id(payload) when is_map(payload) do
      case Map.get(payload, "id") do
        value when is_binary(value) and value != "" -> {:ok, value}
        _other -> {:error, :missing_root_id}
      end
    end

    @spec fetch_params(map()) :: {:ok, map()} | {:error, :invalid_params}
    defp fetch_params(payload) when is_map(payload) do
      case Map.get(payload, "params", %{}) do
        params when is_map(params) -> {:ok, params}
        _other -> {:error, :invalid_params}
      end
    end

    @spec ensure_root_not_mounted(Phoenix.Socket.t(), String.t()) ::
            :ok | {:error, :already_mounted}
    defp ensure_root_not_mounted(%Phoenix.Socket{} = socket, root_id) when is_binary(root_id) do
      if Map.has_key?(mounted_roots(socket), root_id) do
        {:error, :already_mounted}
      else
        :ok
      end
    end

    @spec fetch_declared_root(Phoenix.Socket.t(), String.t()) ::
            {:ok, module()} | {:error, :unknown_root}
    defp fetch_declared_root(%Phoenix.Socket{} = socket, module_str) when is_binary(module_str) do
      socket.assigns
      |> Map.fetch!(@socket_module_key)
      |> Socket.fetch_root_by_module(module_str)
      |> case do
        {:ok, module} -> {:ok, module}
        :error -> {:error, :unknown_root}
      end
    end

    @spec ensure_root_store(module()) :: :ok | {:error, :not_root_store}
    defp ensure_root_store(module) when is_atom(module) do
      with true <- Code.ensure_loaded?(module),
           true <- function_exported?(module, :__arbor__, 1),
           true <- module.__arbor__(:root?) do
        :ok
      else
        _other -> {:error, :not_root_store}
      end
    end

    @spec start_root_page(module(), String.t(), map(), Phoenix.Socket.t()) ::
            {:ok, pid()} | {:error, :missing_connection_socket}
    defp start_root_page(root_module, root_id, params, %Phoenix.Socket{} = socket)
         when is_atom(root_module) and is_binary(root_id) and is_map(params) do
      case Map.fetch(socket.assigns, @connection_socket_key) do
        {:ok, %Socket{} = connection_socket} ->
          root_socket =
            Socket.inherit_context(connection_socket, %Socket{
              assigns: connection_socket.assigns,
              private: %{},
              topic: Map.get(socket.assigns, @topic_key),
              transport_pid: self()
            })

          Server.start_link(
            {root_module, params, root_socket, %{transport_pid: self(), root_id: root_id}}
          )

        :error ->
          {:error, :missing_connection_socket}
      end
    end

    @spec fetch_root_pid(Phoenix.Socket.t(), String.t()) :: {:ok, pid()} | {:error, :unknown_root}
    defp fetch_root_pid(%Phoenix.Socket{} = socket, root_id) when is_binary(root_id) do
      case fetch_root_entry(socket, root_id) do
        {:ok, %{pid: pid}} when is_pid(pid) -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end

    @spec fetch_root_entry(Phoenix.Socket.t(), String.t()) ::
            {:ok, %{pid: pid(), module: module()}} | {:error, :unknown_root}
    defp fetch_root_entry(%Phoenix.Socket{} = socket, root_id) when is_binary(root_id) do
      case Map.fetch(mounted_roots(socket), root_id) do
        {:ok, root_entry} -> {:ok, root_entry}
        :error -> {:error, :unknown_root}
      end
    end

    @spec update_mounted_roots(Phoenix.Socket.t(), (map() -> map())) :: Phoenix.Socket.t()
    defp update_mounted_roots(%Phoenix.Socket{} = socket, fun) when is_function(fun, 1) do
      Phoenix.Socket.assign(socket, @mounted_roots_key, fun.(mounted_roots(socket)))
    end

    @spec mounted_roots(Phoenix.Socket.t()) :: map()
    defp mounted_roots(%Phoenix.Socket{assigns: assigns}) do
      Map.get(assigns, @mounted_roots_key, %{})
    end

    @spec stop_root(pid(), term()) :: :ok
    defp stop_root(pid, reason) when is_pid(pid) do
      # Page servers are started with `start_link/1`; unlink before controlled
      # stops so unmounting one root does not terminate the connection channel.
      Process.unlink(pid)

      if Process.alive?(pid) do
        GenServer.stop(pid, reason, 1_000)
      end

      :ok
    catch
      :exit, _reason -> :ok
    end

    @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, :missing_field}
    defp fetch_string(payload, key) when is_map(payload) and is_binary(key) do
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _other -> {:error, :missing_field}
      end
    end

    @spec error_reason(
            :already_mounted
            | :invalid_params
            | :missing_field
            | :missing_root_id
            | :missing_connection_socket
            | :missing_socket
            | :not_root_store
            | :unauthorized
            | :unknown_root
          ) :: String.t()
    defp error_reason(:already_mounted), do: "root already mounted"
    defp error_reason(:invalid_params), do: "params must be a map"
    defp error_reason(:missing_field), do: "missing required field"
    defp error_reason(:missing_root_id), do: "missing root id"
    defp error_reason(:missing_connection_socket), do: "missing Arbor connection socket"
    defp error_reason(:missing_socket), do: "missing Arbor socket"
    defp error_reason(:not_root_store), do: "declared store is not a root store"
    defp error_reason(:unauthorized), do: "unauthorized"
    defp error_reason(:unknown_root), do: "unknown root"
  end
end
