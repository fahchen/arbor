if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Arbor.Transport.SessionChannel do
    @moduledoc """
    Phoenix Channel adapter for Arbor sessions with multiple root stores.

    The channel owns one Arbor session socket and a dynamic set of root page
    servers. `join/3` runs `Arbor.Session.join/3` once. Each client `"mount"`
    message starts one root store page server using the shared session socket
    assigns and private session context.
    """

    use Phoenix.Channel

    alias Arbor.Page.PatchEnvelope
    alias Arbor.Page.Server
    alias Arbor.Session
    alias Arbor.Socket
    alias Arbor.Telemetry

    # Phoenix socket assign containing the Arbor session module.
    @session_module_key :__arbor_session_module__
    # Phoenix socket assign containing the shared Arbor session socket.
    @session_socket_key :__arbor_session_socket__
    # Phoenix socket assign containing mounted root runtime entries keyed by root id.
    @mounted_roots_key :__arbor_mounted_roots__
    # Phoenix socket assign containing the channel topic.
    @topic_key :__arbor_topic__

    @impl Phoenix.Channel
    @spec join(String.t(), map(), Phoenix.Socket.t()) ::
            {:ok, Phoenix.Socket.t()} | {:error, map()}
    def join(topic, params, %Phoenix.Socket{} = socket)
        when is_binary(topic) and is_map(params) do
      with {:ok, session_module} <- fetch_session_module(socket),
           session_data <- phoenix_session(socket),
           connect_info <- phoenix_connect_info(socket),
           arbor_socket <- build_session_socket(topic, socket, session_data, connect_info),
           {:ok, joined_socket} <- session_module.join(params, session_data, arbor_socket) do
        Telemetry.emit(
          [:arbor, :channel, :join],
          %{system_time: System.system_time()},
          %{module: session_module, id: nil, topic: topic, page_pid: nil}
        )

        {:ok,
         socket
         |> Phoenix.Socket.assign(@session_module_key, session_module)
         |> Phoenix.Socket.assign(@session_socket_key, joined_socket)
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
      with {:ok, root_name} <- fetch_string(payload, "root"),
           {:ok, root_id} <- fetch_root_id(payload, root_name),
           {:ok, params} <- fetch_params(payload),
           :ok <- ensure_root_not_mounted(socket, root_id),
           {:ok, root_module} <- fetch_declared_root(socket, root_name),
           :ok <- ensure_root_store!(root_module),
           {:ok, page_pid} <- start_root_page(root_module, root_id, params, socket) do
        Process.link(page_pid)

        root_entry = %{pid: page_pid, module: root_module, name: root_name}

        socket = update_mounted_roots(socket, &Map.put(&1, root_id, root_entry))

        {:reply, {:ok, %{"root_id" => root_id}}, socket}
      else
        {:error, reason} -> {:reply, {:error, %{reason: error_reason(reason)}}, socket}
      end
    end

    def handle_in("command", %{"name" => name} = payload, %Phoenix.Socket{} = socket)
        when is_binary(name) do
      with {:ok, root_id} <- fetch_string(payload, "root_id"),
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
      session_module = Map.get(socket.assigns, @session_module_key)

      Telemetry.emit(
        [:arbor, :channel, :terminate],
        %{system_time: System.system_time()},
        %{
          module: session_module,
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

    @spec fetch_session_module(Phoenix.Socket.t()) :: {:ok, module()} | {:error, :missing_session}
    defp fetch_session_module(%Phoenix.Socket{handler: handler}) when is_atom(handler) do
      if function_exported?(handler, :__arbor_session__, 0) do
        {:ok, handler.__arbor_session__()}
      else
        {:error, :missing_session}
      end
    end

    @spec phoenix_session(Phoenix.Socket.t()) :: map()
    defp phoenix_session(%Phoenix.Socket{assigns: assigns}) do
      Map.get(assigns, :__arbor_session__, %{})
    end

    @spec phoenix_connect_info(Phoenix.Socket.t()) :: map()
    defp phoenix_connect_info(%Phoenix.Socket{assigns: assigns}) do
      Map.get(assigns, :__arbor_connect_info__, %{})
    end

    @spec build_session_socket(String.t(), Phoenix.Socket.t(), map(), map()) :: Socket.t()
    defp build_session_socket(topic, %Phoenix.Socket{} = phoenix_socket, session, connect_info)
         when is_binary(topic) and is_map(session) and is_map(connect_info) do
      %Socket{
        assigns: shared_assigns(phoenix_socket),
        private: %{},
        topic: topic,
        transport_pid: self()
      }
      |> Socket.put_session(session)
      |> Socket.put_connect_info(connect_info)
    end

    @spec shared_assigns(Phoenix.Socket.t()) :: map()
    defp shared_assigns(%Phoenix.Socket{assigns: assigns}) do
      assigns
      |> Enum.reject(fn {key, _value} -> internal_assign_key?(key) end)
      |> Map.new()
    end

    @spec internal_assign_key?(atom() | String.t()) :: boolean()
    defp internal_assign_key?(key) when is_atom(key) do
      key |> Atom.to_string() |> String.starts_with?("__arbor_")
    end

    defp internal_assign_key?(key) when is_binary(key) do
      String.starts_with?(key, "__arbor_")
    end

    @spec fetch_root_id(map(), String.t()) :: {:ok, String.t()} | {:error, :missing_root_id}
    defp fetch_root_id(payload, fallback) when is_map(payload) and is_binary(fallback) do
      case Map.get(payload, "id") || Map.get(payload, "root_id") || fallback do
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
    defp fetch_declared_root(%Phoenix.Socket{} = socket, root_name) when is_binary(root_name) do
      socket.assigns
      |> Map.fetch!(@session_module_key)
      |> Session.fetch_root(root_name)
      |> case do
        {:ok, module} -> {:ok, module}
        :error -> {:error, :unknown_root}
      end
    end

    @spec ensure_root_store!(module()) :: :ok | {:error, :not_root_store}
    defp ensure_root_store!(module) when is_atom(module) do
      with true <- Code.ensure_loaded?(module),
           true <- function_exported?(module, :__arbor__, 1),
           true <- module.__arbor__(:root?) do
        :ok
      else
        _other -> {:error, :not_root_store}
      end
    end

    @spec start_root_page(module(), String.t(), map(), Phoenix.Socket.t()) ::
            {:ok, pid()} | {:error, :missing_session_socket}
    defp start_root_page(root_module, root_id, params, %Phoenix.Socket{} = socket)
         when is_atom(root_module) and is_binary(root_id) and is_map(params) do
      case Map.fetch(socket.assigns, @session_socket_key) do
        {:ok, %Socket{} = session_socket} ->
          root_socket =
            Socket.inherit_context(session_socket, %Socket{
              assigns: session_socket.assigns,
              private: %{},
              topic: Map.get(socket.assigns, @topic_key),
              transport_pid: self()
            })

          Server.start_link(
            {root_module, params, root_socket, %{transport_pid: self(), root_id: root_id}}
          )

        :error ->
          {:error, :missing_session_socket}
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
            {:ok, %{pid: pid(), module: module(), name: String.t()}} | {:error, :unknown_root}
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
            | :missing_session
            | :missing_session_socket
            | :not_root_store
            | :unauthorized
            | :unknown_root
          ) :: String.t()
    defp error_reason(:already_mounted), do: "root already mounted"
    defp error_reason(:invalid_params), do: "params must be a map"
    defp error_reason(:missing_field), do: "missing required field"
    defp error_reason(:missing_root_id), do: "missing root id"
    defp error_reason(:missing_session), do: "missing Arbor session"
    defp error_reason(:missing_session_socket), do: "missing Arbor session socket"
    defp error_reason(:not_root_store), do: "declared store is not a root store"
    defp error_reason(:unauthorized), do: "unauthorized"
    defp error_reason(:unknown_root), do: "unknown root"
  end
end
