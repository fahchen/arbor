defmodule Arbor.Socket do
  @moduledoc "Socket struct and assign helpers for Arbor runtimes."

  use TypedStructor

  @typedoc "Keys written into the assigns map."
  @type assign_key :: term()

  @typedoc "Path segments identifying a store's parent path."
  @type path_segment :: atom() | String.t()

  @typedoc "The private bookkeeping map carried by the socket."
  @type private_key :: term()

  typed_structor do
    field(:assigns, map(), default: %{})
    field(:id, String.t() | nil, default: nil)
    field(:parent_path, [path_segment()], default: [])
    field(:module, module() | nil, default: nil)
    field(:endpoint, module() | nil, default: nil)
    field(:topic, String.t() | nil, default: nil)
    field(:transport_pid, pid() | nil, default: nil)
    field(:private, map(), default: %{})
  end

  @doc "Assigns a single key on the socket and tracks it in `__changed__` when the value changes."
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

  @doc "Assigns many keys from a keyword list or map."
  @spec assign(t(), keyword(term()) | map()) :: t()
  def assign(%__MODULE__{} = socket, attrs) when is_list(attrs) or is_map(attrs) do
    Enum.reduce(attrs, socket, fn {key, value}, acc -> assign(acc, key, value) end)
  end

  @doc "Updates one assign by applying `fun` to the current value."
  @spec update_assign(t(), assign_key(), (term() -> term())) :: t()
  def update_assign(%__MODULE__{} = socket, key, fun) when is_function(fun, 1) do
    assign(socket, key, fun.(Map.get(socket.assigns, key)))
  end

  @doc "Clears the LV-style `__changed__` bookkeeping after a render cycle."
  @spec reset_changed(t()) :: t()
  def reset_changed(%__MODULE__{} = socket) do
    %{socket | assigns: Map.put(socket.assigns, :__changed__, %{})}
  end

  @doc "Returns whether the given assign key is marked as changed."
  @spec changed?(t(), assign_key()) :: boolean()
  def changed?(%__MODULE__{} = socket, key) do
    socket
    |> ensure_changed()
    |> Map.has_key?(key)
  end

  @doc "Returns whether any consumed key appears in the socket's `__changed__` map."
  @spec consumed_keys_changed?(t(), [assign_key()]) :: boolean()
  def consumed_keys_changed?(%__MODULE__{} = socket, keys) when is_list(keys) do
    changed = ensure_changed(socket)
    Enum.any?(keys, &Map.has_key?(changed, &1))
  end

  @doc "Reads a private runtime value."
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
