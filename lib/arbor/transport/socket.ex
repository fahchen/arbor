if Code.ensure_loaded?(Phoenix.Socket) do
  defmodule Arbor.Transport.Socket do
    @moduledoc """
    Phoenix socket wrapper for Arbor sessions.

    Applications define their own socket module with `use Arbor.Transport.Socket`
    and declare the session module that owns the allowed root stores.

        defmodule MyAppWeb.ArborSocket do
          use Arbor.Transport.Socket, session: MyAppWeb.AppSession
        end

    The Phoenix endpoint mounts that socket module as usual:

        socket "/arbor", MyAppWeb.ArborSocket,
          websocket: [connect_info: [session: @session_options]]
    """

    @doc """
    Declares a Phoenix socket for an Arbor session.

    ## Examples

        defmodule MyAppWeb.ArborSocket do
          use Arbor.Transport.Socket, session: MyAppWeb.AppSession
        end
    """
    @spec __using__(keyword()) :: Macro.t()
    defmacro __using__(opts) do
      session_module =
        opts
        |> Keyword.fetch!(:session)
        |> Macro.expand(__CALLER__)

      quote bind_quoted: [session_module: session_module] do
        use Phoenix.Socket

        channel("arbor:*", Arbor.Transport.SessionChannel)

        @__arbor_session__ session_module

        @impl Phoenix.Socket
        def connect(params, socket, connect_info) do
          {:ok, Arbor.Transport.Socket.assign_connect_context(socket, params, connect_info)}
        end

        @impl Phoenix.Socket
        def id(_socket), do: nil

        defoverridable connect: 3, id: 1

        @doc false
        @spec __arbor_session__() :: module()
        def __arbor_session__, do: @__arbor_session__
      end
    end

    @doc """
    Stores Arbor's connect context on a Phoenix socket.

    Custom Phoenix `connect/3` callbacks can call this after their own auth
    logic to preserve session and connect_info for `Arbor.Session.join/3`.

        def connect(params, socket, connect_info) do
          socket =
            socket
            |> Phoenix.Socket.assign(:current_user, user)
            |> Arbor.Transport.Socket.assign_connect_context(params, connect_info)

          {:ok, socket}
        end
    """
    @spec assign_connect_context(Phoenix.Socket.t(), map(), map()) :: Phoenix.Socket.t()
    def assign_connect_context(%Phoenix.Socket{} = socket, params, connect_info)
        when is_map(params) and is_map(connect_info) do
      session = Map.get(connect_info, :session, %{})

      socket
      |> Phoenix.Socket.assign(:__arbor_connect_params__, params)
      |> Phoenix.Socket.assign(:__arbor_session__, session)
      |> Phoenix.Socket.assign(:__arbor_connect_info__, connect_info)
    end
  end
end
