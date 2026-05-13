defmodule Arbor.Socket do
  @moduledoc "Socket struct and assign helpers for Arbor runtimes."

  use TypedStructor

  # Private key used to expose the params supplied when a root store is mounted.
  @root_params_private_key :__arbor_root_params__
  # Private key used to expose Phoenix session data captured when the Arbor socket connects.
  @session_private_key :__arbor_session__
  # Private key used to expose Phoenix connect_info captured when the Arbor socket connects.
  @connect_info_private_key :__arbor_connect_info__

  @typedoc "Keys written into the assigns map."
  @type assign_key() :: term()

  @typedoc "Path segments identifying a store's parent path."
  @type path_segment() :: atom() | String.t()

  @typedoc "The private bookkeeping map carried by the socket."
  @type private_key() :: term()

  typed_structor do
    field :assigns, map(),
      default: %{},
      doc:
        "Single state container holding parent-supplied attrs and store-internal values together. The only field `render/1` reads from."

    field :id, String.t() | nil,
      default: nil,
      doc:
        "Store node's local id within its parent. Combined with `parent_path` forms the runtime identity (`store_id`). Must be a binary string at the resolver."

    field :parent_path, [path_segment()],
      default: [],
      doc:
        "Ordered list of local ids from the root down to this node's parent. Combined with `id` forms the runtime identity (`store_id`) used for memoization, command routing, async tracking, and telemetry."

    field :module, module() | nil,
      default: nil,
      doc:
        "The store module owning this node. Metadata only — not part of identity. Read-only; set at mount and preserved across re-renders within identity-stable cycles."

    field :endpoint, module() | nil,
      default: nil,
      doc:
        "Phoenix endpoint module. Provided so hooks and helpers can broadcast or push outside the standard envelope flow when needed."

    field :topic, String.t() | nil,
      default: nil,
      doc: "Phoenix Channel topic for the connected page session."

    field :transport_pid, pid() | nil,
      default: nil,
      doc:
        "Pid of the Phoenix Channel process bound 1:1 to this page runtime (BDR-0003). Termination of the transport pid terminates the page server."

    field :private, map(),
      default: %{},
      doc:
        "Reserved for runtime bookkeeping (hook table at `:hooks`, async ref tracking, pending stream ops). Do not read or write directly; use `get_private/3` and `put_private/3`."
  end

  @typedoc "Runtime identity of a store node — array of local ids from root."
  @type store_id() :: [String.t()]

  @typedoc "Client params supplied for the current root store mount."
  @type root_params() :: map()

  @typedoc "Session data shared by all root stores on one Arbor socket."
  @type session() :: map()

  @typedoc "Phoenix connect_info data captured when the Arbor socket connects."
  @type connect_info() :: map()

  @doc """
  Returns the runtime identity (`store_id`) of the store node owning this socket.

  The store_id is the array of local id strings from the root down to this
  node. The root has `store_id = []`. Each non-root node has
  `store_id = parent_path ++ [id]`.

  ## Examples

      iex> Arbor.Socket.store_id(%Arbor.Socket{parent_path: [], id: ""})
      []

      iex> Arbor.Socket.store_id(%Arbor.Socket{parent_path: [], id: "filters"})
      ["filters"]

      iex> Arbor.Socket.store_id(%Arbor.Socket{parent_path: ["filters"], id: "primary"})
      ["filters", "primary"]
  """
  @spec store_id(t()) :: store_id()
  def store_id(%__MODULE__{parent_path: [], id: nil}), do: []
  def store_id(%__MODULE__{parent_path: [], id: ""}), do: []

  def store_id(%__MODULE__{parent_path: parent_path, id: id})
      when is_list(parent_path) and is_binary(id) do
    parent_path
    |> Enum.map(&to_string/1)
    |> List.insert_at(-1, id)
  end

  @doc """
  Assigns one key on the socket and records the change in `__changed__`.

  ## Examples

      iex> socket = %Arbor.Socket{}
      iex> socket = Arbor.Socket.assign(socket, :title, "Inbox")
      iex> socket.assigns.title
      "Inbox"
      iex> socket.assigns.__changed__
      %{title: true}
  """
  @spec assign(t(), assign_key(), term()) :: t()
  def assign(%__MODULE__{} = socket, key, value) do
    current_assigns = ensure_changed_map(socket.assigns)
    current_value = Map.get(current_assigns, key)

    if current_value === value do
      %{socket | assigns: current_assigns}
    else
      changed =
        current_assigns
        |> Map.get(:__changed__, %{})
        |> Map.put(key, true)

      next_assigns =
        current_assigns
        |> Map.put(:__changed__, changed)
        |> Map.put(key, value)

      %{socket | assigns: next_assigns}
    end
  end

  @doc """
  Assigns many keys from a keyword list or map.

  ## Examples

      iex> socket = %Arbor.Socket{}
      iex> socket = Arbor.Socket.assign(socket, %{title: "Inbox", count: 2})
      iex> socket.assigns.title
      "Inbox"
      iex> socket.assigns.count
      2
  """
  @spec assign(t(), keyword(term()) | map()) :: t()
  def assign(%__MODULE__{} = socket, attrs) when is_list(attrs) or is_map(attrs) do
    Enum.reduce(attrs, socket, fn {key, value}, acc -> assign(acc, key, value) end)
  end

  @doc """
  Updates one assign by applying `fun` to the current value.

  ## Examples

      iex> socket = Arbor.Socket.assign(%Arbor.Socket{}, :count, 1)
      iex> socket = Arbor.Socket.update_assign(socket, :count, &(&1 + 1))
      iex> socket.assigns.count
      2
  """
  @spec update_assign(t(), assign_key(), (term() -> term())) :: t()
  def update_assign(%__MODULE__{} = socket, key, fun) when is_function(fun, 1) do
    assign(socket, key, fun.(Map.get(socket.assigns, key)))
  end

  @doc """
  Clears the LiveView-style `__changed__` bookkeeping after a render cycle.

  ## Examples

      iex> socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "Inbox")
      iex> Arbor.Socket.reset_changed(socket).assigns.__changed__
      %{}
  """
  @spec reset_changed(t()) :: t()
  def reset_changed(%__MODULE__{} = socket) do
    %{socket | assigns: Map.put(socket.assigns, :__changed__, %{})}
  end

  @doc """
  Returns whether the given assign key is marked as changed.

  ## Examples

      iex> socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "Inbox")
      iex> Arbor.Socket.changed?(socket, :title)
      true
      iex> Arbor.Socket.changed?(socket, :count)
      false
  """
  @spec changed?(t(), assign_key()) :: boolean()
  def changed?(%__MODULE__{} = socket, key) do
    socket
    |> ensure_changed()
    |> Map.has_key?(key)
  end

  @doc """
  Returns whether any consumed key appears in the socket's `__changed__` map.

  ## Examples

      iex> socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "Inbox")
      iex> Arbor.Socket.consumed_keys_changed?(socket, [:title, :count])
      true
      iex> Arbor.Socket.consumed_keys_changed?(socket, [:count])
      false
  """
  @spec consumed_keys_changed?(t(), [assign_key()]) :: boolean()
  def consumed_keys_changed?(%__MODULE__{} = socket, keys) when is_list(keys) do
    changed = ensure_changed(socket)
    Enum.any?(keys, &Map.has_key?(changed, &1))
  end

  @doc """
  Returns whether any assign key is marked as changed since the last render cycle.

  ## Examples

      iex> Arbor.Socket.any_changed?(%Arbor.Socket{})
      false
      iex> socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "Inbox")
      iex> Arbor.Socket.any_changed?(socket)
      true
  """
  @spec any_changed?(t()) :: boolean()
  def any_changed?(%__MODULE__{} = socket) do
    socket
    |> ensure_changed()
    |> map_size() > 0
  end

  @doc """
  Reads a private runtime value.

  ## Examples

      iex> socket = %Arbor.Socket{private: %{hooks: %{}}}
      iex> Arbor.Socket.get_private(socket, :hooks)
      %{}
      iex> Arbor.Socket.get_private(socket, :missing, :fallback)
      :fallback
  """
  @spec get_private(t(), private_key(), term()) :: term()
  def get_private(%__MODULE__{} = socket, key, default \\ nil) do
    Map.get(socket.private, key, default)
  end

  @doc """
  Stores the current root store mount params in socket private context.

  ## Examples

      iex> socket = Arbor.Socket.put_root_params(%Arbor.Socket{}, %{"poll_id" => "p1"})
      iex> Arbor.Socket.root_params(socket)
      %{"poll_id" => "p1"}
  """
  @spec put_root_params(t(), root_params()) :: t()
  def put_root_params(%__MODULE__{} = socket, params) when is_map(params) do
    put_private(socket, @root_params_private_key, params)
  end

  @doc """
  Returns the params supplied when the current root store was mounted.

  ## Examples

      iex> Arbor.Socket.root_params(%Arbor.Socket{})
      %{}
  """
  @spec root_params(t()) :: root_params()
  def root_params(%__MODULE__{} = socket) do
    get_private(socket, @root_params_private_key, %{})
  end

  @doc """
  Stores session data shared by all root stores on one Arbor socket.

  ## Examples

      iex> socket = Arbor.Socket.put_session(%Arbor.Socket{}, %{"user_id" => "u1"})
      iex> Arbor.Socket.session(socket)
      %{"user_id" => "u1"}
  """
  @spec put_session(t(), session()) :: t()
  def put_session(%__MODULE__{} = socket, session) when is_map(session) do
    put_private(socket, @session_private_key, session)
  end

  @doc """
  Returns the session data shared by all root stores on one Arbor socket.

  ## Examples

      iex> Arbor.Socket.session(%Arbor.Socket{})
      %{}
  """
  @spec session(t()) :: session()
  def session(%__MODULE__{} = socket) do
    get_private(socket, @session_private_key, %{})
  end

  @doc """
  Stores Phoenix connect_info data on the Arbor socket.

  ## Examples

      iex> socket = Arbor.Socket.put_connect_info(%Arbor.Socket{}, %{peer_data: %{address: {127, 0, 0, 1}}})
      iex> Arbor.Socket.connect_info(socket)
      %{peer_data: %{address: {127, 0, 0, 1}}}
  """
  @spec put_connect_info(t(), connect_info()) :: t()
  def put_connect_info(%__MODULE__{} = socket, connect_info) when is_map(connect_info) do
    put_private(socket, @connect_info_private_key, connect_info)
  end

  @doc """
  Returns Phoenix connect_info data captured when the Arbor socket connected.

  ## Examples

      iex> Arbor.Socket.connect_info(%Arbor.Socket{})
      %{}
  """
  @spec connect_info(t()) :: connect_info()
  def connect_info(%__MODULE__{} = socket) do
    get_private(socket, @connect_info_private_key, %{})
  end

  @doc """
  Copies shared Arbor context from one socket to another.

  The copied context includes session and connect_info. Root params are
  intentionally per-root and are not copied.

  ## Examples

      iex> source = Arbor.Socket.put_session(%Arbor.Socket{}, %{"user_id" => "u1"})
      iex> target = Arbor.Socket.inherit_context(source, %Arbor.Socket{})
      iex> Arbor.Socket.session(target)
      %{"user_id" => "u1"}
  """
  @spec inherit_context(t(), t()) :: t()
  def inherit_context(%__MODULE__{} = source, %__MODULE__{} = target) do
    Enum.reduce(context_private_keys(), target, fn key, acc ->
      case Map.fetch(source.private, key) do
        {:ok, value} -> put_private(acc, key, value)
        :error -> acc
      end
    end)
  end

  @doc false
  @spec put_private(t(), private_key(), term()) :: t()
  def put_private(%__MODULE__{} = socket, key, value) do
    %{socket | private: Map.put(socket.private, key, value)}
  end

  @spec context_private_keys() :: [private_key()]
  defp context_private_keys do
    [@session_private_key, @connect_info_private_key]
  end

  @spec ensure_changed(t()) :: map()
  defp ensure_changed(%__MODULE__{} = socket) do
    socket.assigns
    |> ensure_changed_map()
    |> Map.get(:__changed__, %{})
  end

  @spec ensure_changed_map(map()) :: map()
  defp ensure_changed_map(assigns) when is_map(assigns) do
    case Map.get(assigns, :__changed__) do
      changed when is_map(changed) -> assigns
      _other -> Map.put(assigns, :__changed__, %{})
    end
  end
end
