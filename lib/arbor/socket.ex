defmodule Arbor.Socket do
  @moduledoc "Socket struct and assign helpers for Arbor runtimes."

  use TypedStructor

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

  @doc false
  @spec put_private(t(), private_key(), term()) :: t()
  def put_private(%__MODULE__{} = socket, key, value) do
    %{socket | private: Map.put(socket.private, key, value)}
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
