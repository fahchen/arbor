defmodule Arbor.Reconciler do
  @moduledoc "Child identity, lifecycle, attr-defaulting, and disappearance handling for Arbor render resolution."

  alias Arbor.Child
  alias Arbor.DSL.Attr
  alias Arbor.Page.StoreTable
  alias Arbor.Page.StoreTable.Entry
  alias Arbor.Socket
  alias Arbor.Stream
  alias Arbor.Telemetry

  @type identity_key() :: StoreTable.key()

  @type reconcile_result() ::
          {:mount, identity_key(), Socket.t(), [Socket.assign_key()]}
          | {:update, identity_key(), Socket.t(), [Socket.assign_key()]}
          | {:reuse, identity_key(), Entry.t(), [Socket.assign_key()]}

  @doc """
  Reconciles one child placeholder against the existing registry entry.

  Returns a tagged action describing whether the child must mount, update, or
  can reuse the previously resolved output. The returned `identity_key` is the
  child's `store_id` (parent's `store_id ++ [local id]`).

  ## Examples

      iex> parent_socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "Inbox")
      iex> child = Arbor.Child.child(ExampleChild, id: "child", title: "Inbox")
      iex> {:mount, ["child"], %Arbor.Socket{}, [:title]} =
      ...>   Arbor.Reconciler.reconcile_child(child, parent_socket, [], Arbor.Page.StoreTable.new())
  """
  @spec reconcile_child(Child.t(), Socket.t(), [String.t()], StoreTable.t()) ::
          reconcile_result()
  def reconcile_child(
        %Child{} = child,
        %Socket{} = parent_socket,
        parent_path,
        %StoreTable{} = registry
      )
      when is_list(parent_path) do
    id = validate_id!(child)
    assigns = normalize_assigns(child.module, child.assigns)
    consumed_keys = Map.keys(assigns)
    store_id = List.insert_at(parent_path, -1, id)

    case StoreTable.get(registry, store_id) do
      %Entry{module: existing_module} = entry when existing_module == child.module ->
        cond do
          Socket.consumed_keys_changed?(parent_socket, consumed_keys) ->
            next_socket = update_store(entry.socket, assigns)
            {:update, store_id, next_socket, consumed_keys}

          parent_assign_values_changed?(entry.socket, assigns, consumed_keys) ->
            next_socket = update_store(entry.socket, assigns)
            {:update, store_id, next_socket, consumed_keys}

          # Child has internal mutations queued (from a command handler, an
          # async result write, or a stream insert) since the last render. The
          # parent did not change so `update/2` does not run, but the child
          # still needs to re-render so its new state surfaces in the wire diff.
          child_store_dirty?(entry.socket) ->
            {:update, store_id, entry.socket, consumed_keys}

          true ->
            {:reuse, store_id, %{entry | consumed_keys: consumed_keys}, consumed_keys}
        end

      _missing_or_module_change ->
        {:mount, store_id,
         new_child_socket(parent_socket, parent_path, child.module, id, assigns), consumed_keys}
    end
  end

  @spec parent_assign_values_changed?(Socket.t(), map(), [Socket.assign_key()]) :: boolean()
  defp parent_assign_values_changed?(%Socket{} = socket, assigns, consumed_keys)
       when is_map(assigns) and is_list(consumed_keys) do
    Enum.any?(consumed_keys, fn key ->
      case Map.fetch(socket.assigns, key) do
        {:ok, current_value} -> current_value !== Map.fetch!(assigns, key)
        :error -> true
      end
    end)
  end

  @spec child_store_dirty?(Socket.t()) :: boolean()
  defp child_store_dirty?(%Socket{} = socket) do
    Socket.any_changed?(socket) or stream_changed?(socket)
  end

  defp stream_changed?(%Socket{} = socket) do
    socket
    |> Stream.changed_streams()
    |> MapSet.size() > 0
  end

  @doc """
  Runs the store initialization callback and returns the initialized socket.

  ## Examples

      iex> defmodule ReconcilerMountDocStore do
      ...>   def init(socket), do: {:ok, Arbor.Socket.assign(socket, :mounted?, true)}
      ...> end
      iex> socket = %Arbor.Socket{module: ReconcilerMountDocStore}
      iex> Arbor.Reconciler.init_store(socket).assigns.mounted?
      true
  """
  @spec init_store(Socket.t()) :: Socket.t()
  def init_store(%Socket{module: module} = socket) when is_atom(module) do
    {result, fun, arity} =
      cond do
        function_exported?(module, :init, 1) ->
          {module.init(socket), :init, 1}

        function_exported?(module, :mount, 1) ->
          {module.mount(socket), :mount, 1}

        true ->
          {{:ok, socket}, :init, 1}
      end

    result
    |> validate_callback_result!(module, fun, arity)
    |> validate_required_fields!(module)
  end

  # Catches the most common pre-render bug: a store declares
  # `field :foo, T` (non-nullable primitive) but `mount/init` returns
  # without assigning it. Without this check, `render/1` blew up later
  # inside `ValidateRender` with a stack pointing at the
  # wire-serialisation path, which made the failure read as a render
  # bug rather than a mount bug.
  #
  # Conservative scope: only primitive-typed fields are checked. Child
  # slot fields (`Module.t()`) live in render output, not assigns;
  # stream slots (`stream(T)`, `AsyncResult.of(stream(_))`) live under
  # the reserved `:__streams__` key. Both are excluded so the check
  # has no false positives in those cases.
  @spec validate_required_fields!(Socket.t(), module()) :: Socket.t()
  defp validate_required_fields!(%Socket{assigns: assigns} = socket, module) do
    if function_exported?(module, :__arbor__, 1) do
      missing =
        for %{name: name, type: type} <- module.__arbor__(:fields),
            primitive_value_field?(type),
            not type_includes_nil?(type),
            is_nil(Map.get(assigns, name)),
            do: name

      case missing do
        [] ->
          socket

        _missing ->
          raise ArgumentError,
                "#{inspect(module)} mount returned without assigning required fields: " <>
                  "#{inspect(missing)}. Assign them in the mount/init callback, or mark " <>
                  "each nullable (`field #{inspect(hd(missing))}, T | nil`)."
      end
    else
      socket
    end
  end

  # Strict whitelist: only fields with primitive value types are
  # checked. Composite forms (`Module.t()`, `Module.of(_)`, `stream(_)`,
  # `list(_)`, `map()`, struct-shaped maps) can be slot-like or
  # runtime-managed, and there is no reliable way to distinguish at
  # the AST level. The whitelist catches the original pain case
  # (`field :created_at, String.t()`) with zero false positives.
  @spec primitive_value_field?(Macro.t()) :: boolean()
  defp primitive_value_field?({:|, _meta, alts}), do: Enum.all?(alts, &primitive_value_field?/1)
  defp primitive_value_field?({:string, _meta, []}), do: true
  defp primitive_value_field?({:binary, _meta, []}), do: true
  defp primitive_value_field?({:integer, _meta, []}), do: true
  defp primitive_value_field?({:float, _meta, []}), do: true
  defp primitive_value_field?({:boolean, _meta, []}), do: true
  defp primitive_value_field?({:atom, _meta, []}), do: true

  defp primitive_value_field?({{:., _dot, [{:__aliases__, _meta, [:String]}, :t]}, _call, []}),
    do: true

  defp primitive_value_field?(literal)
       when is_atom(literal) or is_binary(literal) or is_number(literal),
       do: true

  defp primitive_value_field?(_other), do: false

  @spec type_includes_nil?(Macro.t()) :: boolean()
  defp type_includes_nil?({:|, _meta, alternatives}),
    do: Enum.any?(alternatives, &type_includes_nil?/1)

  defp type_includes_nil?(nil), do: true
  defp type_includes_nil?(_other), do: false

  @doc """
  Runs the legacy store mount callback.

  This function remains as a compatibility wrapper for callers using the old
  `mount/1` naming. New code should call `init_store/1`.

  ## Examples

      iex> defmodule ReconcilerLegacyMountDocStore do
      ...>   def mount(socket), do: {:ok, Arbor.Socket.assign(socket, :mounted?, true)}
      ...> end
      iex> socket = %Arbor.Socket{module: ReconcilerLegacyMountDocStore}
      iex> Arbor.Reconciler.mount_store(socket).assigns.mounted?
      true
  """
  @spec mount_store(Socket.t()) :: Socket.t()
  def mount_store(%Socket{} = socket) do
    init_store(socket)
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

    validate_callback_result!(result, module, :update, 2)
  end

  @doc """
  Drops any registry entries not observed in the latest render tree.

  A dropped child emits a skeleton lazy-discard telemetry event so M5 can hook
  into the same path when async delivery arrives after disappearance.

  ## Examples

      iex> entry = %Arbor.Page.StoreTable.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> registry =
      ...>   Arbor.Page.StoreTable.put(
      ...>     Arbor.Page.StoreTable.new(),
      ...>     ["root"],
      ...>     entry
      ...>   )
      iex> Arbor.Reconciler.prune_stale_entries(registry, %{})
      %Arbor.Page.StoreTable{entries: %{}}
  """
  @spec prune_stale_entries(StoreTable.t(), map()) :: StoreTable.t()
  def prune_stale_entries(%StoreTable{} = registry, live_identities)
      when is_map(live_identities) do
    Enum.reduce(StoreTable.keys(registry), registry, fn store_id, acc ->
      if Map.has_key?(live_identities, store_id) do
        acc
      else
        emit_lazy_discard(store_id, registry)
        StoreTable.delete(acc, store_id)
      end
    end)
  end

  @doc false
  @spec normalize_assigns(module(), map()) :: map()
  def normalize_assigns(module, assigns) when is_atom(module) and is_map(assigns) do
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

  @spec emit_lazy_discard(identity_key(), StoreTable.t()) :: :ok
  defp emit_lazy_discard(store_id, %StoreTable{} = registry) do
    module =
      case StoreTable.get(registry, store_id) do
        %Entry{module: module} -> module
        nil -> nil
      end

    Telemetry.emit(
      [:arbor, :async, :lazy_discard],
      %{count: 1},
      %{store_id: store_id, module: module}
    )
  end

  @spec new_child_socket(Socket.t(), [String.t()], module(), String.t(), map()) :: Socket.t()
  defp new_child_socket(%Socket{} = parent_socket, parent_path, module, id, assigns)
       when is_list(parent_path) and is_atom(module) and is_binary(id) and is_map(assigns) do
    Socket.assign(
      Socket.inherit_context(parent_socket, %Socket{
        id: id,
        parent_path: parent_path,
        module: module,
        assigns: %{},
        private: %{}
      }),
      assigns
    )
  end

  @spec validate_callback_result!({:ok, Socket.t()} | tuple(), module(), atom(), pos_integer()) ::
          Socket.t()
  defp validate_callback_result!({:ok, %Socket{} = socket}, module, fun, arity)
       when is_atom(module) and is_atom(fun) and is_integer(arity) do
    socket
  end

  defp validate_callback_result!(other, module, fun, arity)
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
