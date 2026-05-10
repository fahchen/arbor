if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Arbor.Transport.Channel do
    @moduledoc """
    Reference Phoenix Channel adapter that binds an `Arbor.Page.Server` 1:1 to
    a connected channel session.

    ## Usage

    Wire the channel inside a Phoenix.Socket and route the incoming `"command"`
    events through `Arbor.Page.Server.command/4`. Patch envelopes pushed by
    the runtime arrive as `{:patch, %Arbor.Page.PatchEnvelope{}}` messages and
    are forwarded to the client as `"patch"` events.

        defmodule MyAppWeb.PageChannel do
          use Arbor.Transport.Channel, root: MyApp.RootStore
        end

    The macro injects the standard `Phoenix.Channel` callbacks. Override any
    of them in the host module to customize join/disconnect behavior.

    ## Wire shape

    Incoming `"command"` payload:

        %{"path" => ["filters"], "name" => "change_query", "payload" => %{...}}

    The Phoenix Channel `ref` is managed by the channel transport itself —
    Phoenix associates the reply with the originating push automatically, so
    the page server is never given the ref.

    Outgoing `"patch"` payload — `Arbor.Page.PatchEnvelope.to_wire/1`:

        %{
          "type" => "patch",
          "base_version" => 0,
          "version" => 1,
          "ops" => [...],
          "stream_ops" => [...]
        }
    """

    alias Arbor.Page.PatchEnvelope
    alias Arbor.Page.Server

    @doc false
    defmacro __using__(opts) do
      root_module = Keyword.fetch!(opts, :root)

      quote do
        use Phoenix.Channel

        @doc false
        @impl Phoenix.Channel
        def join(_topic, params, socket) do
          Arbor.Transport.Channel.__join__(unquote(root_module), params, socket)
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

        defoverridable join: 3, handle_in: 3, handle_info: 2
      end
    end

    @doc false
    @spec __join__(module(), map(), Phoenix.Socket.t()) :: {:ok, Phoenix.Socket.t()}
    def __join__(root_module, params, %Phoenix.Socket{} = socket) when is_atom(root_module) do
      {:ok, page_pid} =
        Server.start_link({root_module, params, %{transport_pid: self()}})

      Process.link(page_pid)
      {:ok, Phoenix.Socket.assign(socket, :__arbor_page__, page_pid)}
    end

    @doc false
    @spec __handle_command__(map(), Phoenix.Socket.t()) ::
            {:reply, {:ok, map()}, Phoenix.Socket.t()}
    def __handle_command__(%{"name" => name} = payload, %Phoenix.Socket{} = socket)
        when is_binary(name) do
      page_pid = Map.fetch!(socket.assigns, :__arbor_page__)
      path = Map.get(payload, "path", [])
      command_payload = Map.get(payload, "payload", %{})

      command_name = String.to_existing_atom(name)

      {:ok, reply} = Server.command(page_pid, path, command_name, command_payload)

      {:reply, {:ok, reply}, socket}
    end

    @doc false
    @spec __handle_patch__(PatchEnvelope.t(), Phoenix.Socket.t()) ::
            {:noreply, Phoenix.Socket.t()}
    def __handle_patch__(%PatchEnvelope{} = envelope, %Phoenix.Socket{} = socket) do
      Phoenix.Channel.push(socket, "patch", PatchEnvelope.to_wire(envelope))
      {:noreply, socket}
    end
  end
end
