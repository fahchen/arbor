defmodule Arbor.Session do
  @moduledoc """
  Declares the root stores that can share one Arbor socket.

  A session runs `join/3` once for the Phoenix socket join. The returned
  `Arbor.Socket` carries shared assigns, session data, and connect_info for
  every root store mounted later on the same socket.
  """

  alias Arbor.Socket

  @type root_name() :: atom()
  @type roots() :: keyword(module())
  @type join_params() :: map()
  @type session_data() :: map()
  @type join_error() :: :error | {:error, :unauthorized | :not_found | :invalid_params}
  @type join_result() :: {:ok, Socket.t()} | join_error()

  @doc """
  Authorizes one Arbor socket join and prepares shared socket assigns.
  """
  @callback join(params :: join_params(), session :: session_data(), socket :: Socket.t()) ::
              join_result()

  @doc """
  Declares an Arbor session module.

  ## Examples

      defmodule MyAppWeb.AppSession do
        use Arbor.Session,
          roots: [
            dashboard: MyApp.Stores.DashboardStore,
            poll_room: MyApp.Stores.PollRoomStore
          ]

        @impl Arbor.Session
        def join(_params, session, socket) do
          {:ok, Arbor.Socket.assign(socket, :user_id, session["user_id"])}
        end
      end
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    roots = opts |> Keyword.fetch!(:roots) |> normalize_roots!(__CALLER__)

    quote bind_quoted: [roots: roots] do
      @behaviour Arbor.Session

      @__arbor_roots__ roots

      @impl Arbor.Session
      def join(_params, _session, socket), do: {:ok, socket}

      defoverridable join: 3

      @doc false
      @spec __arbor_roots__() :: Arbor.Session.roots()
      def __arbor_roots__, do: @__arbor_roots__
    end
  end

  @doc """
  Fetches a declared root store module by atom or client string name.

  The client string is compared against already-declared root names; Arbor does
  not convert arbitrary strings into atoms.

  ## Examples

      iex> defmodule SessionFetchRootDoc do
      ...>   defmodule Store do
      ...>   end
      ...>
      ...>   use Arbor.Session, roots: [dashboard: Store]
      ...> end
      iex> Arbor.Session.fetch_root(SessionFetchRootDoc, "dashboard")
      {:ok, SessionFetchRootDoc.Store}
      iex> Arbor.Session.fetch_root(SessionFetchRootDoc, "missing")
      :error
  """
  @spec fetch_root(module(), root_name() | String.t()) :: {:ok, module()} | :error
  def fetch_root(session_module, root_name)
      when is_atom(session_module) and (is_atom(root_name) or is_binary(root_name)) do
    session_module
    |> session_roots()
    |> Enum.find(fn {declared_name, _module} -> root_matches?(declared_name, root_name) end)
    |> case do
      {_declared_name, module} -> {:ok, module}
      nil -> :error
    end
  end

  @spec session_roots(module()) :: roots()
  defp session_roots(session_module) when is_atom(session_module) do
    if function_exported?(session_module, :__arbor_roots__, 0) do
      session_module.__arbor_roots__()
    else
      []
    end
  end

  @spec root_matches?(root_name(), root_name() | String.t()) :: boolean()
  defp root_matches?(declared_name, requested_name) when is_atom(requested_name) do
    declared_name == requested_name
  end

  defp root_matches?(declared_name, requested_name) when is_binary(requested_name) do
    Atom.to_string(declared_name) == requested_name
  end

  @spec normalize_roots!(list(), Macro.Env.t()) :: roots()
  defp normalize_roots!(roots, %Macro.Env{} = env) when is_list(roots) do
    Enum.map(roots, fn
      {name, module_ast} when is_atom(name) ->
        module = Macro.expand(module_ast, env)

        unless is_atom(module) do
          raise ArgumentError,
                "Arbor.Session root #{inspect(name)} must point at a module, got: #{inspect(module_ast)}"
        end

        {name, module}

      other ->
        raise ArgumentError,
              "Arbor.Session roots must be a keyword list of root_name: StoreModule, got: #{inspect(other)}"
    end)
  end
end
