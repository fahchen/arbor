if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Arbor.Transport.Channel do
    @moduledoc """
    Reference Phoenix Channel adapter that binds an `Arbor.Page.Server` 1:1 to
    a connected channel session.

    ## Mounting in a Phoenix endpoint

    Wire the channel inside a Phoenix.Socket and route the incoming `"command"`
    events through `Arbor.Page.Server.command/4`. Patch envelopes pushed by
    the runtime arrive as `{:patch, %Arbor.Page.PatchEnvelope{}}` messages and
    are forwarded to the client as `"patch"` events.

        defmodule MyAppWeb.PageChannel do
          use Arbor.Transport.Channel, root: MyApp.RootStore
        end

        defmodule MyAppWeb.UserSocket do
          use Phoenix.Socket

          channel "page:*", MyAppWeb.PageChannel

          def connect(_params, socket, _connect_info), do: {:ok, socket}
          def id(_socket), do: nil
        end

    Then attach the socket to the endpoint:

        defmodule MyAppWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :my_app

          socket "/socket", MyAppWeb.UserSocket,
            websocket: true,
            longpoll: false
        end

    ## Lifecycle

    On `join/3` the adapter starts a fresh `Arbor.Page.Server` and links it
    to the channel pid. The page server's `transport_pid` is set to the
    channel pid so patch envelopes flow back as `{:patch, envelope}` messages
    that the adapter forwards to the client as `"patch"` events.

    On channel `terminate/2` the linked page server receives `:EXIT` and
    stops via `BDR-0003` let-it-crash. Reconnect is recovery (BDR-0015):
    each new join builds a fresh page server with `version: 1` and an
    initial `replace ""` envelope. There is no in-memory state preserved
    across disconnects.

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

    ## Telemetry

    The adapter emits two adapter-scoped events:

      * `[:arbor, :channel, :join]` — `%{system_time: integer}`. Metadata:
        `module`, `topic`, `page_pid`.
      * `[:arbor, :channel, :terminate]` — `%{system_time: integer}`.
        Metadata: `module`, `topic`, `reason`, `page_pid`.

    Runtime-scoped events (`[:arbor, :command, …]`, `[:arbor, :patch, :stop]`,
    etc.) keep emitting from the page server and are catalogued in
    `Arbor.Telemetry.events/0`.
    """

    alias Arbor.Page.PatchEnvelope
    alias Arbor.Page.Server
    alias Arbor.Telemetry

    @doc false
    defmacro __using__(opts) do
      root_module = Keyword.fetch!(opts, :root)

      quote do
        use Phoenix.Channel

        @doc false
        @impl Phoenix.Channel
        def join(topic, params, socket) do
          Arbor.Transport.Channel.__join__(unquote(root_module), topic, params, socket)
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
          Arbor.Transport.Channel.__terminate__(unquote(root_module), reason, socket)
        end

        defoverridable join: 3, handle_in: 3, handle_info: 2, terminate: 2
      end
    end

    @doc false
    @spec __join__(module(), String.t(), map(), Phoenix.Socket.t()) ::
            {:ok, Phoenix.Socket.t()}
    def __join__(root_module, topic, params, %Phoenix.Socket{} = socket)
        when is_atom(root_module) and is_binary(topic) do
      {:ok, page_pid} =
        Server.start_link({root_module, params, %{transport_pid: self()}})

      Process.link(page_pid)

      Telemetry.emit(
        [:arbor, :channel, :join],
        %{system_time: System.system_time()},
        %{module: root_module, topic: topic, page_pid: page_pid}
      )

      {:ok,
       socket
       |> Phoenix.Socket.assign(:__arbor_page__, page_pid)
       |> Phoenix.Socket.assign(:__arbor_root__, root_module)
       |> Phoenix.Socket.assign(:__arbor_topic__, topic)}
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

    @doc false
    @spec __terminate__(module(), term(), Phoenix.Socket.t()) :: :ok
    def __terminate__(root_module, reason, %Phoenix.Socket{} = socket) do
      page_pid = Map.get(socket.assigns, :__arbor_page__)
      topic = Map.get(socket.assigns, :__arbor_topic__)

      Telemetry.emit(
        [:arbor, :channel, :terminate],
        %{system_time: System.system_time()},
        %{module: root_module, topic: topic, reason: reason, page_pid: page_pid}
      )

      # The page server is linked to the channel pid; the impending exit
      # delivers `:EXIT` and the page server stops on its own. We unlink+stop
      # explicitly so the page server's `terminate/2` runs with the original
      # reason rather than a noproc-style EXIT.
      if is_pid(page_pid) and Process.alive?(page_pid) do
        Process.unlink(page_pid)
        GenServer.stop(page_pid, :shutdown, 1_000)
      end

      :ok
    end
  end
end
