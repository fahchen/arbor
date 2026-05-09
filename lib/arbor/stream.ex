defmodule Arbor.Stream do
  @moduledoc """
  LV-parity stream API for Arbor stores.

  Stream-typed slots (declared via `stream/2,3` inside `state do`) carry
  collections whose **values** the page server forgets after each flush — only
  the ordered list of `item_key`s is retained server-side. Items reach the
  client through the envelope's `stream_ops`, never through JSON Patch ops
  (BDR-0014, BDR-0018).

  ## Public API surface (frozen for M5+)

    * `stream/3,4`
    * `stream_configure/3`
    * `stream_insert/3,4`
    * `stream_delete/3`
    * `stream_delete_by_item_key/3`

  Argument shapes mirror Phoenix.LiveView with one rename: Arbor uses
  `_by_item_key` where LV uses `_by_dom_id`.

  ## Reserved socket keys

    * `socket.assigns.__streams__` — `%{name => %{config: ..., item_keys: [...]}}`.
    * `socket.private[:__arbor_pending_stream_ops__]` — accumulated ops for
      this handler invocation (in queue order).
    * `socket.private[:__arbor_stream_seen__]` — set of stream names that
      have a non-configure op queued in the current handler invocation.

  These keys are runtime-internal; do not read or write directly.

  ## Examples

      Arbor.Stream.stream_insert(socket, :messages, %{id: "1", body: "hi"})
      #=> %Arbor.Socket{...}
  """

  alias Arbor.Page.PatchEnvelope
  alias Arbor.Socket
  alias Arbor.Telemetry
  alias Arbor.Wire

  @typedoc "Public stream identifier — atom matching a `stream :name, T, ...` declaration."
  @type stream_name() :: atom()

  @typedoc "Computed item_key returned by the configured `:item_key` capture. Always a binary."
  @type item_key() :: String.t()

  @typedoc "Per-store stream config — runtime-merged from compile-time reflection + `stream_configure/3`."
  @type config() :: %{
          required(:item_key) => (term() -> item_key()),
          required(:limit) => integer() | nil
        }

  @typedoc "Server-side per-stream state."
  @type stream_state() :: %{required(:config) => config(), required(:item_keys) => [item_key()]}

  @typedoc "Stream op pushed in the envelope's `stream_ops` array."
  @type op() ::
          %{required(:op) => String.t(), required(:name) => String.t(), optional(any()) => any()}

  @assigns_key :__streams__
  @pending_key :__arbor_pending_stream_ops__
  @seen_key :__arbor_stream_seen__

  @doc """
  Returns the reserved socket-assigns key holding the per-stream index.

  Exposed so tests and hooks can introspect without hard-coding the literal.
  """
  @spec assigns_key() :: :__streams__
  def assigns_key, do: @assigns_key

  @doc """
  Returns the reserved socket-private key holding pending stream ops.
  """
  @spec pending_key() :: :__arbor_pending_stream_ops__
  def pending_key, do: @pending_key

  @doc """
  Configures runtime overrides for a declared stream slot.

  Must precede any non-configure op for the same `name` in the current
  handler invocation; calling it after `stream_insert/4` etc. raises.

  ## Examples

      socket = Arbor.Stream.stream_configure(socket, :messages, item_key: &("custom-" <> &1.id))
  """
  @spec stream_configure(Socket.t(), stream_name(), keyword()) :: Socket.t()
  def stream_configure(%Socket{} = socket, name, opts) when is_atom(name) and is_list(opts) do
    if seen_non_configure?(socket, name) do
      raise ArgumentError,
            "stream_configure(:#{name}, ...) must precede other stream ops in the same handler"
    end

    base_config = ensure_config(socket, name)
    overrides = build_config_overrides(opts, name)
    next_config = Map.merge(base_config, overrides)

    socket
    |> put_stream_config(name, next_config)
    |> queue_op(%{op: "configure", name: Atom.to_string(name)}, configure?: true)
  end

  @doc """
  Bulk seeds or refreshes a stream slot.

  With `reset: true`, queues a `reset` op before the per-item inserts so the
  client clears the local stream before applying them.

  ## Examples

      socket = Arbor.Stream.stream(socket, :messages, [%{id: "1", body: "hi"}])
      socket = Arbor.Stream.stream(socket, :messages, fresh_items, reset: true)
  """
  @spec stream(Socket.t(), stream_name(), [term()], keyword()) :: Socket.t()
  def stream(socket, name, items, opts \\ [])

  def stream(%Socket{} = socket, name, items, opts)
      when is_atom(name) and is_list(items) and is_list(opts) do
    {reset?, opts} = Keyword.pop(opts, :reset, false)

    socket =
      if reset? do
        reset_stream(socket, name)
      else
        ensure_stream_initialized(socket, name)
      end

    Enum.reduce(items, socket, fn item, acc ->
      stream_insert(acc, name, item, opts)
    end)
  end

  @doc """
  Inserts (or upserts) one item into a stream slot.

  The default position is `:at` `-1` (append). `:update_only true` skips the
  call when the item's `item_key` is not currently in the slot. Insertions
  that grow the index past `:limit` queue a matching `delete` for the
  evicted key in the same envelope (per `streams/lifecycle`).

  ## Examples

      socket = Arbor.Stream.stream_insert(socket, :messages, %{id: "1", body: "hi"})
      socket = Arbor.Stream.stream_insert(socket, :messages, item, at: 0, limit: -100)
  """
  @spec stream_insert(Socket.t(), stream_name(), term(), keyword()) :: Socket.t()
  def stream_insert(socket, name, item, opts \\ [])

  def stream_insert(%Socket{} = socket, name, item, opts)
      when is_atom(name) and is_list(opts) do
    socket = ensure_stream_initialized(socket, name)
    config = current_config(socket, name)

    item_key = compute_item_key(socket, name, opts, config, item)
    update_only? = Keyword.get(opts, :update_only, false)
    position = Keyword.get(opts, :at, -1)
    limit = Keyword.get(opts, :limit, config.limit)

    state = stream_state(socket, name)
    exists? = item_key in state.item_keys

    cond do
      update_only? and not exists? ->
        socket

      exists? ->
        # Upsert: per BDR streams/lifecycle, length is unchanged → no limit
        # re-evaluation, no delete emitted.
        queue_op(socket, insert_op(name, item_key, item, position))

      true ->
        next_keys = position_insert(state.item_keys, item_key, position)
        {evicted, kept_keys} = apply_limit(next_keys, limit)

        socket
        |> put_stream_state(name, %{state | item_keys: kept_keys})
        |> queue_op(insert_op(name, item_key, item, position))
        |> queue_evictions(name, evicted)
    end
  end

  @doc """
  Deletes one item from a stream slot by deriving its `item_key` from the item.

  ## Examples

      socket = Arbor.Stream.stream_delete(socket, :messages, %{id: "1"})
  """
  @spec stream_delete(Socket.t(), stream_name(), term()) :: Socket.t()
  def stream_delete(%Socket{} = socket, name, item) when is_atom(name) do
    socket = ensure_stream_initialized(socket, name)
    config = current_config(socket, name)
    item_key = compute_item_key(socket, name, [], config, item)
    stream_delete_by_item_key(socket, name, item_key)
  end

  @doc """
  Deletes one item from a stream slot directly by `item_key`.

  No-op when the key is not currently indexed server-side.

  ## Examples

      socket = Arbor.Stream.stream_delete_by_item_key(socket, :messages, "messages-1")
  """
  @spec stream_delete_by_item_key(Socket.t(), stream_name(), item_key()) :: Socket.t()
  def stream_delete_by_item_key(%Socket{} = socket, name, item_key)
      when is_atom(name) and is_binary(item_key) do
    socket = ensure_stream_initialized(socket, name)
    state = stream_state(socket, name)

    if item_key in state.item_keys do
      next_keys = List.delete(state.item_keys, item_key)

      socket
      |> put_stream_state(name, %{state | item_keys: next_keys})
      |> queue_op(%{op: "delete", name: Atom.to_string(name), item_key: item_key})
    else
      socket
    end
  end

  @doc """
  Pops every pending stream op into queue order and clears the accumulator.

  Called by the page runtime once per handler invocation, immediately before
  building the patch envelope. After the call, `socket.private` no longer
  carries any pending stream ops or the configure-precedence tracking set.

  ## Examples

      {ops, socket} = Arbor.Stream.flush_pending_ops(socket)
      ops
      #=> [%{op: "insert", name: "messages", item_key: "messages-1", item: %{...}, at: -1}]
  """
  @spec flush_pending_ops(Socket.t()) :: {[op()], Socket.t()}
  def flush_pending_ops(%Socket{} = socket) do
    pending = pending_ops(socket)

    Telemetry.emit(
      [:arbor, :stream, :flush],
      %{count: length(pending)},
      %{module: socket.module}
    )

    next_socket =
      socket
      |> Socket.put_private(@pending_key, [])
      |> Socket.put_private(@seen_key, MapSet.new())

    {pending, next_socket}
  end

  @doc """
  Returns the queued (but not yet flushed) stream ops for the current handler.

  Useful to peek the accumulator without clearing it (tests, debugging).

  ## Examples

      socket = Arbor.Stream.stream_insert(%Arbor.Socket{module: M}, :messages, %{id: "1"})
      length(Arbor.Stream.pending_ops(socket))
      #=> 1
  """
  @spec pending_ops(Socket.t()) :: [op()]
  def pending_ops(%Socket{} = socket) do
    socket
    |> Socket.get_private(@pending_key, [])
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Internal: state shape helpers
  # ---------------------------------------------------------------------------

  defp ensure_stream_initialized(%Socket{} = socket, name) do
    case stream_state(socket, name) do
      nil ->
        config = ensure_config(socket, name)

        Socket.assign(
          socket,
          @assigns_key,
          Map.put(streams_index(socket), name, %{config: config, item_keys: []})
        )

      _state ->
        socket
    end
  end

  defp ensure_config(%Socket{module: module}, name) when is_atom(module) do
    if module && function_exported?(module, :__arbor_stream_config__, 1) do
      module.__arbor_stream_config__(name)
    else
      raise ArgumentError,
            "stream :#{name} not declared on module #{inspect(module)} — declare it inside state do."
    end
  end

  defp streams_index(%Socket{assigns: assigns}), do: Map.get(assigns, @assigns_key, %{})

  defp stream_state(%Socket{} = socket, name) do
    socket |> streams_index() |> Map.get(name)
  end

  defp put_stream_state(%Socket{} = socket, name, state) do
    Socket.assign(socket, @assigns_key, Map.put(streams_index(socket), name, state))
  end

  defp current_config(%Socket{} = socket, name) do
    case stream_state(socket, name) do
      %{config: config} -> config
      nil -> ensure_config(socket, name)
    end
  end

  defp put_stream_config(%Socket{} = socket, name, config) do
    state = stream_state(socket, name) || %{config: config, item_keys: []}
    put_stream_state(socket, name, %{state | config: config})
  end

  # ---------------------------------------------------------------------------
  # Internal: item_key + limit + position
  # ---------------------------------------------------------------------------

  defp compute_item_key(%Socket{module: module}, name, opts, config, item) do
    fun =
      case Keyword.fetch(opts, :item_key) do
        {:ok, override} -> validate_item_key_override!(override, name)
        :error -> Map.fetch!(config, :item_key)
      end

    invoke_item_key!(fun, item, module, name)
  end

  defp validate_item_key_override!(fun, _name) when is_function(fun, 1), do: fun

  defp validate_item_key_override!(other, name) do
    raise ArgumentError,
          "stream_insert(:#{name}, item, item_key: ...) expects an arity-1 function, got: #{inspect(other)}"
  end

  defp invoke_item_key!(fun, item, module, name) do
    result = fun.(item)

    if is_binary(result) do
      result
    else
      raise ArgumentError,
            "stream :#{name} item_key on #{inspect(module)} must return a binary, got: #{inspect(result)}"
    end
  rescue
    error in [KeyError] ->
      reraise ArgumentError,
              "stream :#{name} on #{inspect(module)}: item is missing the `:id` field required " <>
                "by the default item_key — got #{inspect(item)} (KeyError: #{Exception.message(error)})",
              __STACKTRACE__

    error in [ArgumentError] ->
      reraise error, __STACKTRACE__
  end

  defp position_insert(list, key, -1), do: List.insert_at(list, -1, key)
  defp position_insert(list, key, 0), do: [key | list]

  defp position_insert(list, key, index) when is_integer(index) and index > 0 do
    List.insert_at(list, index, key)
  end

  defp position_insert(_list, _key, other) do
    raise ArgumentError,
          "stream_insert :at expects -1, 0, or a positive integer, got: #{inspect(other)}"
  end

  defp apply_limit(keys, nil), do: {[], keys}
  defp apply_limit(keys, 0), do: {keys, []}

  defp apply_limit(keys, limit) when is_integer(limit) and limit > 0 do
    excess = length(keys) - limit

    if excess > 0 do
      {Enum.take(keys, -excess), Enum.take(keys, limit)}
    else
      {[], keys}
    end
  end

  defp apply_limit(keys, limit) when is_integer(limit) and limit < 0 do
    abs_limit = -limit
    excess = length(keys) - abs_limit

    if excess > 0 do
      {Enum.take(keys, excess), Enum.take(keys, -abs_limit)}
    else
      {[], keys}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: op accumulator
  # ---------------------------------------------------------------------------

  defp insert_op(name, item_key, item, position) do
    %{
      op: "insert",
      name: Atom.to_string(name),
      item_key: item_key,
      item: Wire.to_wire(item),
      at: position
    }
  end

  defp queue_evictions(socket, name, evicted_keys) do
    Enum.reduce(evicted_keys, socket, fn key, acc ->
      queue_op(acc, %{op: "delete", name: Atom.to_string(name), item_key: key})
    end)
  end

  defp queue_op(%Socket{} = socket, op, opts \\ []) do
    configure? = Keyword.get(opts, :configure?, false)

    pending = Socket.get_private(socket, @pending_key, [])
    seen = Socket.get_private(socket, @seen_key, MapSet.new())
    name = atom_name(op)

    next_seen = if configure?, do: seen, else: MapSet.put(seen, name)

    socket
    |> Socket.put_private(@pending_key, [op | pending])
    |> Socket.put_private(@seen_key, next_seen)
  end

  defp atom_name(%{name: bin}) when is_binary(bin), do: String.to_existing_atom(bin)

  defp seen_non_configure?(%Socket{} = socket, name) do
    socket
    |> Socket.get_private(@seen_key, MapSet.new())
    |> MapSet.member?(name)
  end

  defp reset_stream(%Socket{} = socket, name) do
    socket = ensure_stream_initialized(socket, name)
    state = stream_state(socket, name)

    socket
    |> put_stream_state(name, %{state | item_keys: []})
    |> queue_op(%{op: "reset", name: Atom.to_string(name)})
  end

  defp build_config_overrides(opts, name) do
    Enum.reduce(opts, %{}, fn
      {:item_key, fun}, acc ->
        Map.put(acc, :item_key, validate_item_key_override!(fun, name))

      {:limit, limit}, acc when is_integer(limit) or is_nil(limit) ->
        Map.put(acc, :limit, limit)

      {key, value}, _acc ->
        raise ArgumentError,
              "stream_configure(:#{name}, ...) does not accept option #{inspect({key, value})}"
    end)
  end

  @doc false
  @spec __envelope_struct__() :: module()
  def __envelope_struct__, do: PatchEnvelope
end
