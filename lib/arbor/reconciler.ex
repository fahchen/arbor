defmodule Arbor.Reconciler do
  @moduledoc "Child identity, lifecycle, attr-defaulting, and disappearance handling for Arbor render resolution."

  alias Arbor.Child
  alias Arbor.DSL.Attr
  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Socket
  alias Arbor.Telemetry

  @type identity_key() :: StoreRegistry.identity_key()

  @type reconcile_result() ::
          {:mount, identity_key(), Socket.t(), [Socket.assign_key()]}
          | {:update, identity_key(), Socket.t(), [Socket.assign_key()]}
          | {:reuse, identity_key(), Entry.t(), [Socket.assign_key()]}

  @doc """
  Reconciles one child placeholder against the existing registry entry.

  Returns a tagged action describing whether the child must mount, update, or
  can reuse the previously resolved output.

  ## Examples

      iex> parent_socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "Inbox")
      iex> child = Arbor.Child.child(ExampleChild, id: "child", title: "Inbox")
      iex> {:mount, {[], ExampleChild, "child"}, %Arbor.Socket{}, [:title]} =
      ...>   Arbor.Reconciler.reconcile_child(child, parent_socket, [], Arbor.Page.StoreRegistry.new())
  """
  @spec reconcile_child(Child.t(), Socket.t(), [String.t()], StoreRegistry.t()) ::
          reconcile_result()
  def reconcile_child(
        %Child{} = child,
        %Socket{} = parent_socket,
        parent_path,
        %StoreRegistry{} = registry
      )
      when is_list(parent_path) do
    id = validate_id!(child)
    assigns = normalize_child_assigns(child.module, child.assigns)
    consumed_keys = Map.keys(assigns)
    identity = {parent_path, child.module, id}

    case StoreRegistry.get(registry, parent_path, child.module, id) do
      %Entry{} = entry ->
        if Socket.consumed_keys_changed?(parent_socket, consumed_keys) do
          next_socket = update_store(entry.socket, assigns)
          {:update, identity, next_socket, consumed_keys}
        else
          {:reuse, identity, %{entry | consumed_keys: consumed_keys}, consumed_keys}
        end

      nil ->
        {:mount, identity, new_child_socket(parent_path, child.module, id, assigns),
         consumed_keys}
    end
  end

  @doc """
  Runs `mount/1` when present; otherwise returns the original socket.

  ## Examples

      iex> defmodule ReconcilerMountDocStore do
      ...>   def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :mounted?, true)}
      ...> end
      iex> socket = %Arbor.Socket{module: ReconcilerMountDocStore}
      iex> Arbor.Reconciler.mount_store(socket).assigns.mounted?
      true
  """
  @spec mount_store(Socket.t()) :: Socket.t()
  def mount_store(%Socket{module: module} = socket) when is_atom(module) do
    result =
      if function_exported?(module, :mount, 1) do
        module.mount(socket)
      else
        {:ok, socket}
      end

    validate_callback_result!(module, :mount, 1, result)
  end

  @doc """
  Runs `update/2` when present; otherwise merges the new assigns into the socket.

  ## Examples

      iex> defmodule ReconcilerUpdateDocStore do
      ...>   def update(assigns, socket), do: {:ok, Arbor.Socket.assign(socket, assigns)}
      ...> end
      iex> socket = %Arbor.Socket{module: ReconcilerUpdateDocStore, assigns: %{}, private: %{}}
      iex> Arbor.Reconciler.update_store(socket, %{title: "Inbox"}).assigns.title
      "Inbox"
  """
  @spec update_store(Socket.t(), map()) :: Socket.t()
  def update_store(%Socket{module: module} = socket, new_assigns)
      when is_atom(module) and is_map(new_assigns) do
    result =
      if function_exported?(module, :update, 2) do
        module.update(new_assigns, socket)
      else
        {:ok, Socket.assign(socket, new_assigns)}
      end

    validate_callback_result!(module, :update, 2, result)
  end

  @doc """
  Drops any registry entries not observed in the latest render tree.

  A dropped child emits a skeleton lazy-discard telemetry event so M5 can hook
  into the same path when async delivery arrives after disappearance.

  ## Examples

      iex> entry = %Arbor.Page.StoreRegistry.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> registry =
      ...>   Arbor.Page.StoreRegistry.put(
      ...>     Arbor.Page.StoreRegistry.new(),
      ...>     [],
      ...>     Example,
      ...>     "root",
      ...>     entry
      ...>   )
      iex> Arbor.Reconciler.prune_stale_entries(registry, %{})
      %Arbor.Page.StoreRegistry{entries: %{}}
  """
  @spec prune_stale_entries(StoreRegistry.t(), map()) :: StoreRegistry.t()
  def prune_stale_entries(%StoreRegistry{} = registry, live_identities)
      when is_map(live_identities) do
    Enum.reduce(StoreRegistry.keys(registry), registry, fn identity, acc ->
      if Map.has_key?(live_identities, identity) do
        acc
      else
        emit_lazy_discard(identity)
        delete_identity(acc, identity)
      end
    end)
  end

  @doc false
  @spec normalize_child_assigns(module(), map()) :: map()
  def normalize_child_assigns(module, assigns) when is_atom(module) and is_map(assigns) do
    attrs =
      if function_exported?(module, :__arbor__, 1) do
        module.__arbor__(:attrs)
      else
        []
      end

    Enum.reduce(attrs, assigns, fn %{name: name, required: required, default: default}, acc ->
      cond do
        Map.has_key?(acc, name) ->
          acc

        default != Attr.no_default() ->
          Map.put(acc, name, default)

        required ->
          raise ArgumentError,
                "missing required attr #{inspect(name)} for child #{inspect(module)}"

        true ->
          acc
      end
    end)
  end

  @spec delete_identity(StoreRegistry.t(), identity_key()) :: StoreRegistry.t()
  defp delete_identity(%StoreRegistry{} = registry, {parent_path, module, id}) do
    StoreRegistry.delete(registry, parent_path, module, id)
  end

  @spec emit_lazy_discard(identity_key()) :: :ok
  defp emit_lazy_discard({parent_path, module, id}) do
    Telemetry.emit(
      [:arbor, :async, :lazy_discard],
      %{count: 1},
      %{parent_path: parent_path, module: module, id: id}
    )
  end

  @spec new_child_socket([String.t()], module(), String.t(), map()) :: Socket.t()
  defp new_child_socket(parent_path, module, id, assigns)
       when is_list(parent_path) and is_atom(module) and is_binary(id) and is_map(assigns) do
    Socket.assign(
      %Socket{id: id, parent_path: parent_path, module: module, assigns: %{}, private: %{}},
      assigns
    )
  end

  @spec validate_callback_result!(module(), atom(), pos_integer(), {:ok, Socket.t()} | tuple()) ::
          Socket.t()
  defp validate_callback_result!(module, fun, arity, {:ok, %Socket{} = socket})
       when is_atom(module) and is_atom(fun) and is_integer(arity) do
    socket
  end

  defp validate_callback_result!(module, fun, arity, other)
       when is_atom(module) and is_atom(fun) and is_integer(arity) do
    raise ArgumentError,
          "bad callback response from #{inspect(module)}.#{fun}/#{arity}: expected {:ok, %Arbor.Socket{}}, got #{inspect(other)}"
  end

  @spec validate_id!(Child.t()) :: String.t()
  defp validate_id!(%Child{id: id, module: _module}) when is_binary(id), do: id

  defp validate_id!(%Child{id: nil, module: module}) do
    raise ArgumentError, "child #{inspect(module)} is missing required :id"
  end

  defp validate_id!(%Child{id: id, module: module}) do
    raise ArgumentError,
          "child #{inspect(module)} id must be a binary string, got: #{inspect(id)}"
  end
end
