defmodule Arbor.Session do
  @moduledoc """
  Declares the root stores that can share one Arbor socket.

  A session runs `join/3` once for the Phoenix socket join. The returned
  `Arbor.Socket` carries shared assigns, session data, and connect_info for
  every root store mounted later on the same socket.
  """

  alias Arbor.Socket

  @type roots() :: [module()]
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
            MyApp.Stores.DashboardStore,
            MyApp.Stores.PollRoomStore
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
  Fetches a declared root store module by its client module string.

  The string is compared against modules already declared in the session;
  Arbor does not convert arbitrary strings into atoms.

  ## Examples

      iex> defmodule SessionFetchRootByModuleDoc do
      ...>   defmodule Store do
      ...>     use Arbor.Store, root: true
      ...>
      ...>     state do
      ...>       field :ok, boolean()
      ...>     end
      ...>
      ...>     def render(_socket), do: %{ok: true}
      ...>     def handle_command(_name, _payload, socket), do: {:noreply, socket}
      ...>   end
      ...>
      ...>   use Arbor.Session, roots: [Store]
      ...> end
      iex> Arbor.Session.fetch_root_by_module(SessionFetchRootByModuleDoc, "SessionFetchRootByModuleDoc.Store")
      {:ok, SessionFetchRootByModuleDoc.Store}
      iex> Arbor.Session.fetch_root_by_module(SessionFetchRootByModuleDoc, "Missing.Store")
      :error
  """
  @spec fetch_root_by_module(module(), String.t()) :: {:ok, module()} | :error
  def fetch_root_by_module(session_module, module_str)
      when is_atom(session_module) and is_binary(module_str) do
    session_module
    |> session_roots()
    |> Enum.find(&module_matches?(&1, module_str))
    |> case do
      nil -> :error
      module when is_atom(module) -> {:ok, module}
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

  @spec module_matches?(module(), String.t()) :: boolean()
  defp module_matches?(module, module_str) when is_atom(module) and is_binary(module_str) do
    module |> Module.split() |> Enum.join(".") == module_str
  end

  @spec normalize_roots!([Macro.t()], Macro.Env.t()) :: roots()
  defp normalize_roots!(roots, %Macro.Env{} = env) when is_list(roots) do
    if roots != [] and Keyword.keyword?(roots) do
      raise ArgumentError,
            "Arbor.Session roots must be a list of StoreModule modules, got keyword entries: #{inspect(roots)}"
    end

    Enum.map(roots, fn module_ast ->
      module = Macro.expand(module_ast, env)

      unless is_atom(module) do
        raise ArgumentError,
              "Arbor.Session root must be a module, got: #{inspect(module_ast)}"
      end

      validate_root_store!(module)
      module
    end)
  end

  @spec validate_root_store!(module()) :: :ok
  defp validate_root_store!(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, "Arbor.Session root module #{inspect(module)} is not loadable"

      not function_exported?(module, :__arbor__, 1) ->
        raise ArgumentError,
              "Arbor.Session root module #{inspect(module)} must use Arbor.Store, root: true"

      module.__arbor__(:root?) ->
        :ok

      true ->
        raise ArgumentError,
              "Arbor.Session root module #{inspect(module)} must use Arbor.Store, root: true"
    end
  end
end
