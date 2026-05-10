defmodule Arbor.Resolver do
  @moduledoc """
  Public render resolver for Arbor store trees.

  `resolve/2` renders the given store socket, resolves any `child(...)`
  placeholders bottom-up, then for each rendered store runs the lifecycle
  pipeline:

    1. `:after_to_state` hooks — receive the resolved Elixir term.
    2. `Arbor.Wire.to_wire/1` — converts the resolved Elixir term to wire form.
    3. `:after_serialize` hooks — receive the wire term.

  Each rendered store node's resolved state map carries
  `__arbor_store_id__: store_id_array`, the array runtime identity the client
  echoes verbatim when issuing commands.

  After the pipeline, `socket.assigns.__changed__` is reset and the registry
  entry stores both `resolved_state` (Elixir form, used for memoization) and
  `wire_state` (wire form, consumed by the M4 diff engine).

  Return shape:

      {:ok, resolved_root, updated_socket, updated_store_registry}

  `resolved_root` is the Elixir-form output of the root render. The matching
  wire-form root is available via the registry root entry's `:wire_state`.
  """

  alias Arbor.Child
  alias Arbor.Lifecycle
  alias Arbor.Page.StoreRegistry
  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Reconciler
  alias Arbor.Socket
  alias Arbor.Stream
  alias Arbor.Telemetry
  alias Arbor.Wire

  @store_id_key :__arbor_store_id__

  @type resolved_scalar() :: nil | boolean() | number() | String.t() | atom()
  @type resolved_value() ::
          resolved_scalar() | [resolved_value()] | %{optional(term()) => resolved_value()}
  @type resolve_result() :: {:ok, resolved_value(), Socket.t(), StoreRegistry.t()}

  @doc """
  Returns the reserved key name carried on every resolved store-node render output.

  ## Examples

      iex> Arbor.Resolver.store_id_key()
      :__arbor_store_id__
  """
  @spec store_id_key() :: :__arbor_store_id__
  def store_id_key, do: @store_id_key

  @doc """
  Renders one store tree and resolves child placeholders bottom-up.

  ## Examples

      iex> defmodule ResolverDocChild do
      ...>   use Arbor.Store
      ...>   state do
      ...>     field :title, String.t()
      ...>   end
      ...>   def to_state(socket), do: %{title: socket.assigns.title}
      ...> end
      iex> defmodule ResolverDocRoot do
      ...>   use Arbor.Store
      ...>   state do
      ...>     field :child, map()
      ...>   end
      ...>   def to_state(_socket), do: %{child: Arbor.Child.child(ResolverDocChild, id: "child", title: "Inbox")}
      ...> end
      iex> socket = %Arbor.Socket{id: "", parent_path: [], module: ResolverDocRoot, assigns: %{}, private: %{}}
      iex> registry =
      ...>   Arbor.Page.StoreRegistry.put(
      ...>     Arbor.Page.StoreRegistry.new(),
      ...>     [],
      ...>     %Arbor.Page.StoreRegistry.Entry{socket: socket, module: ResolverDocRoot}
      ...>   )
      iex> {:ok, %{child: %{title: "Inbox", __arbor_store_id__: ["child"]}, __arbor_store_id__: []}, _socket, _registry} = Arbor.Resolver.resolve(socket, registry)
  """
  @spec resolve(Socket.t(), StoreRegistry.t()) :: resolve_result()
  def resolve(%Socket{} = socket, %StoreRegistry{} = registry) do
    resolve_started_at = System.monotonic_time()

    {resolved_root, updated_socket, updated_registry, live_identities} =
      render_store(socket, registry, %{})

    final_registry = Reconciler.prune_stale_entries(updated_registry, live_identities)

    Telemetry.emit(
      [:arbor, :resolve, :stop],
      %{duration: System.monotonic_time() - resolve_started_at},
      %{module: socket.module, store_id: Socket.store_id(socket)}
    )

    {:ok, resolved_root, updated_socket, final_registry}
  end

  defp render_store(%Socket{} = socket, %StoreRegistry{} = registry, live_identities)
       when is_map(live_identities) do
    raw_state = socket.module.to_state(socket)
    store_id = Socket.store_id(socket)

    {resolved_state, resolved_registry, resolved_live_identities} =
      resolve_value(raw_state, socket, registry, store_id, live_identities)

    resolved_state = inject_store_id(resolved_state, store_id)

    after_to_state_socket =
      case Lifecycle.run_hooks(socket, :after_to_state, [resolved_state], false) do
        {:cont, %Socket{} = hooked_socket} -> hooked_socket
        {:halt, %Socket{} = hooked_socket} -> hooked_socket
      end

    wire_state = Wire.to_wire(resolved_state)

    next_socket =
      case Lifecycle.run_hooks(after_to_state_socket, :after_serialize, [wire_state], false) do
        {:cont, %Socket{} = hooked_socket} ->
          hooked_socket
          |> Stream.drain_and_prune()
          |> Socket.reset_changed()

        {:halt, %Socket{} = hooked_socket} ->
          hooked_socket
          |> Stream.drain_and_prune()
          |> Socket.reset_changed()
      end

    next_registry =
      StoreRegistry.put(
        resolved_registry,
        store_id,
        %Entry{
          socket: next_socket,
          module: next_socket.module,
          resolved_state: resolved_state,
          wire_state: wire_state,
          consumed_keys: entry_consumed_keys(registry, store_id)
        }
      )

    next_live_identities = Map.put(resolved_live_identities, store_id, true)

    {resolved_state, next_socket, next_registry, next_live_identities}
  end

  defp inject_store_id(resolved_state, store_id) when is_map(resolved_state) do
    Map.put(resolved_state, @store_id_key, store_id)
  end

  defp inject_store_id(resolved_state, _store_id), do: resolved_state

  defp resolve_value(
         %Child{} = child,
         %Socket{} = parent_socket,
         %StoreRegistry{} = registry,
         path,
         live
       )
       when is_list(path) do
    resolve_child(child, parent_socket, registry, path, live)
  end

  defp resolve_value(value, %Socket{} = parent_socket, %StoreRegistry{} = registry, path, live)
       when is_map(value) and not is_struct(value) do
    Enum.reduce(value, {%{}, registry, live}, fn {key, child_or_value},
                                                 {acc, current_registry, current_live} ->
      if match?(%Child{}, child_or_value) do
        {resolved_child, next_registry, next_live} =
          resolve_child(child_or_value, parent_socket, current_registry, path, current_live)

        {Map.put(acc, key, resolved_child), next_registry, next_live}
      else
        next_path = append_path_segment(path, to_string(key))

        {resolved_child, next_registry, next_live} =
          resolve_value(child_or_value, parent_socket, current_registry, next_path, current_live)

        {Map.put(acc, key, resolved_child), next_registry, next_live}
      end
    end)
  end

  defp resolve_value(value, %Socket{} = parent_socket, %StoreRegistry{} = registry, path, live)
       when is_list(value) do
    {resolved_list, {next_registry, next_live}} =
      Enum.map_reduce(value, {registry, live}, fn element, {current_registry, current_live} ->
        {resolved_element, next_registry, next_live} =
          resolve_value(element, parent_socket, current_registry, path, current_live)

        {resolved_element, {next_registry, next_live}}
      end)

    {resolved_list, next_registry, next_live}
  end

  defp resolve_value(value, _parent_socket, registry, _path, live) do
    {value, registry, live}
  end

  defp resolve_child(
         %Child{} = child,
         %Socket{} = parent_socket,
         %StoreRegistry{} = registry,
         path,
         live
       )
       when is_list(path) do
    case Reconciler.reconcile_child(child, parent_socket, path, registry) do
      {:reuse, store_id, %Entry{} = entry, consumed_keys} ->
        ensure_unique_identity!(store_id, live)

        next_registry =
          StoreRegistry.put(registry, store_id, %{entry | consumed_keys: consumed_keys})

        {entry.resolved_state, next_registry, Map.put(live, store_id, true)}

      {:mount, store_id, %Socket{} = child_socket, consumed_keys} ->
        ensure_unique_identity!(store_id, live)
        mounted_socket = Reconciler.mount_store(child_socket)

        {resolved_state, next_socket, next_registry, next_live} =
          render_store(mounted_socket, registry, live)

        next_registry = put_consumed_keys(next_registry, store_id, consumed_keys)

        {resolved_state, next_socket_registry_socket(next_registry, store_id, next_socket),
         Map.put(next_live, store_id, true)}

      {:update, store_id, %Socket{} = child_socket, consumed_keys} ->
        ensure_unique_identity!(store_id, live)

        {resolved_state, next_socket, next_registry, next_live} =
          render_store(child_socket, registry, live)

        next_registry = put_consumed_keys(next_registry, store_id, consumed_keys)

        {resolved_state, next_socket_registry_socket(next_registry, store_id, next_socket),
         Map.put(next_live, store_id, true)}
    end
  end

  @spec entry_consumed_keys(StoreRegistry.t(), StoreRegistry.identity_key()) ::
          [Socket.assign_key()]
  defp entry_consumed_keys(%StoreRegistry{} = registry, store_id) do
    case StoreRegistry.get(registry, store_id) do
      %Entry{consumed_keys: consumed_keys} -> consumed_keys
      nil -> []
    end
  end

  defp ensure_unique_identity!(store_id, live_identities) do
    if Map.has_key?(live_identities, store_id) do
      raise ArgumentError,
            "duplicate child store_id encountered during reconcile: #{inspect(store_id)} " <>
              "(two children share the same parent and id; ids must be unique among siblings " <>
              "regardless of module)"
    end

    :ok
  end

  @spec put_consumed_keys(StoreRegistry.t(), StoreRegistry.identity_key(), [Socket.assign_key()]) ::
          StoreRegistry.t()
  defp put_consumed_keys(%StoreRegistry{} = registry, store_id, consumed_keys) do
    case StoreRegistry.get(registry, store_id) do
      %Entry{} = entry ->
        StoreRegistry.put(registry, store_id, %{entry | consumed_keys: consumed_keys})

      nil ->
        registry
    end
  end

  @spec next_socket_registry_socket(StoreRegistry.t(), StoreRegistry.identity_key(), Socket.t()) ::
          StoreRegistry.t()
  defp next_socket_registry_socket(%StoreRegistry{} = registry, store_id, socket) do
    case StoreRegistry.get(registry, store_id) do
      %Entry{} = entry ->
        StoreRegistry.put(registry, store_id, %{entry | socket: socket})

      nil ->
        registry
    end
  end

  @spec append_path_segment([String.t()], String.t()) :: [String.t()]
  defp append_path_segment(path, segment) when is_list(path) and is_binary(segment) do
    Enum.reverse([segment | Enum.reverse(path)])
  end
end
