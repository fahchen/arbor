defmodule Musubi.Upload do
  @moduledoc """
  Upload runtime state and op-queue API.

  Per-page upload state lives under `socket.assigns.__uploads__` in this
  shape:

      %{
        __pending_ops__: [op(), ...],        # newest-first
        __seen_config__: MapSet.new([:name]) # uploads that have emitted :config
        <upload_name>: %{
          config: %Musubi.Upload.Config{},
          entries: %{ref => %Musubi.Upload.Entry{}}
        },
        ...
      }

  Per BDR-0025, mutating upload state never marks user-visible assigns
  dirty — the assigns map's `__changed__` is touched only for the
  reserved `__uploads__` key, which `Musubi.Resolver` already filters
  out of the change-tracking signal. Progress chunks therefore do not
  cause the store's `render/1` to re-run.

  ## Public surface

  This module is primarily internal to the runtime, but a few helpers
  are exported via `Musubi.Store` so command handlers can manipulate
  upload state directly:

    * `consume_uploaded_entries/3`
    * `cancel_upload/3`
    * `uploaded_entries/2`
  """

  alias Musubi.Socket
  alias Musubi.Upload.Config
  alias Musubi.Upload.Entry
  alias Musubi.Upload.Error
  alias Musubi.Wire

  @assigns_key :__uploads__
  @pending_ops_key :__pending_ops__
  @seen_config_key :__seen_config__
  @drained_key :__musubi_drained_upload_ops__
  @command_target_key :__musubi_upload_command_target__

  @typedoc "Raw op enqueued from runtime; the page server stamps `store_id` at drain."
  @type raw_op() :: %{required(:op) => String.t(), optional(any()) => any()}

  @typedoc "Wire op carried in `upload_ops`."
  @type op() :: %{
          required(:op) => String.t(),
          required(:upload) => String.t(),
          required(:store_id) => [String.t()],
          optional(any()) => any()
        }

  @doc "Reserved socket-assigns key for the upload index."
  @spec assigns_key() :: :__uploads__
  def assigns_key, do: @assigns_key

  @doc "Reserved socket-private key carrying drained upload ops between resolver and page server."
  @spec drained_key() :: :__musubi_drained_upload_ops__
  def drained_key, do: @drained_key

  @doc "Reserved socket-private key carrying the in-flight command target (set by page server)."
  @spec command_target_key() :: :__musubi_upload_command_target__
  def command_target_key, do: @command_target_key

  # ---------------------------------------------------------------------------
  # Configuration sync (called once per declared upload on mount)
  # ---------------------------------------------------------------------------

  @doc """
  Ensures `socket.assigns.__uploads__` has buckets for every declared
  upload on the store module, and enqueues a `{op: config}` for any
  upload that has not yet broadcast one.

  Returns the updated socket.
  """
  @spec ensure_configs(Socket.t()) :: Socket.t()
  def ensure_configs(%Socket{module: nil} = socket), do: socket

  def ensure_configs(%Socket{module: module} = socket) when is_atom(module) do
    case declared_configs(module) do
      [] ->
        socket

      configs ->
        Enum.reduce(configs, socket, &ensure_one_config/2)
    end
  end

  defp ensure_one_config(%Config{name: name} = config, %Socket{} = socket) do
    index = upload_index(socket)
    bucket = Map.get(index, name)

    cond do
      bucket == nil ->
        new_bucket = %{config: config, entries: %{}}

        socket
        |> put_index(Map.put(index, name, new_bucket))
        |> enqueue_op(%{
          op: "config",
          upload: Atom.to_string(name),
          config: Config.to_wire(config)
        })
        |> mark_seen(name)

      MapSet.member?(seen_configs(socket), name) ->
        socket

      true ->
        socket
        |> enqueue_op(%{
          op: "config",
          upload: Atom.to_string(name),
          config: Config.to_wire(config)
        })
        |> mark_seen(name)
    end
  end

  defp declared_configs(module) when is_atom(module) do
    if function_exported?(module, :__musubi__, 1) do
      List.wrap(module.__musubi__(:uploads))
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers (Store facade surface)
  # ---------------------------------------------------------------------------

  @doc """
  Returns `{completed, in_progress}` for the upload named `name` on the
  current socket. `completed` are entries whose status is `:success`;
  `in_progress` is every other live entry.
  """
  @spec uploaded_entries(Socket.t(), atom()) :: {[Entry.t()], [Entry.t()]}
  def uploaded_entries(%Socket{} = socket, name) when is_atom(name) do
    bucket = upload_index(socket) |> Map.get(name, %{entries: %{}})

    bucket.entries
    |> Map.values()
    |> Enum.split_with(fn %Entry{status: status} -> status == :success end)
  end

  @doc """
  Consumes completed entries with `fun` and removes them from the index
  on `{:ok, val}`. `fun` is invoked with `(meta, entry)` where `meta` is
  `%{path: path}` (channel mode) or `%{external: meta_map}` (external
  mode).

  Returns the list of `val`s produced by successful invocations, in
  entry-order. Postponed entries remain in the index for a later call.

  This may only be called from a command handler; see
  `socket.private[#{inspect(@command_target_key)}]`.
  """
  @spec consume_uploaded_entries(
          Socket.t(),
          atom(),
          (map(), Entry.t() -> {:ok, term()} | {:postpone, term()})
        ) :: {Socket.t(), [term()]}
  def consume_uploaded_entries(%Socket{} = socket, name, fun)
      when is_atom(name) and is_function(fun, 2) do
    unless Socket.get_private(socket, @command_target_key, false) do
      raise ArgumentError,
            "consume_uploaded_entries/3 may only be called inside a command handler"
    end

    {completed, _in_progress} = uploaded_entries(socket, name)
    completed = Enum.sort_by(completed, & &1.preflighted_at)

    Enum.reduce(completed, {socket, []}, fn entry, {sock, results} ->
      meta = consume_meta(entry)

      case fun.(meta, entry) do
        {:ok, value} ->
          # Application has taken ownership of the bytes (e.g. moved
          # the temp file). Remove the entry and delete the temp file
          # so the OS does not leak it.
          cleanup_entry_path(entry)
          sock = remove_entry(sock, name, entry.ref)
          {sock, results ++ [value]}

        {:postpone, value} ->
          # Leave both the index entry and the temp file in place so
          # the application can retry consumption later.
          {sock, results ++ [value]}

        other ->
          raise ArgumentError,
                "consume_uploaded_entries/3 fun must return {:ok, val} or {:postpone, val}, " <>
                  "got: #{inspect(other)}"
      end
    end)
    |> maybe_emit_reset(name)
  end

  @doc """
  Cancels a single upload entry by ref. Emits `{op: cancel}` and
  removes any orphaned temp file (channel mode).
  """
  @spec cancel_upload(Socket.t(), atom(), String.t()) :: Socket.t()
  def cancel_upload(%Socket{} = socket, name, ref) when is_atom(name) and is_binary(ref) do
    case fetch_entry(socket, name, ref) do
      {:ok, %Entry{} = entry} ->
        cleanup_entry_path(entry)

        socket
        |> remove_entry(name, ref)
        |> enqueue_op(%{op: "cancel", upload: Atom.to_string(name), ref: ref})

      :error ->
        socket
    end
  end

  defp cleanup_entry_path(%Entry{mode: :channel, path: path}) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  defp cleanup_entry_path(_entry), do: :ok

  # ---------------------------------------------------------------------------
  # Runtime mutation API (used by Transport.Channel and Transport.UploadChannel)
  # ---------------------------------------------------------------------------

  @doc false
  @spec put_entry(Socket.t(), atom(), Entry.t()) :: Socket.t()
  def put_entry(%Socket{} = socket, name, %Entry{} = entry) when is_atom(name) do
    index = upload_index(socket)
    bucket = Map.get(index, name) || %{config: nil, entries: %{}}
    entries = Map.put(bucket.entries, entry.ref, entry)
    put_index(socket, Map.put(index, name, %{bucket | entries: entries}))
  end

  @doc false
  @spec update_entry(Socket.t(), atom(), String.t(), (Entry.t() -> Entry.t())) :: Socket.t()
  def update_entry(%Socket{} = socket, name, ref, fun)
      when is_atom(name) and is_binary(ref) and is_function(fun, 1) do
    case fetch_entry(socket, name, ref) do
      {:ok, entry} -> put_entry(socket, name, fun.(entry))
      :error -> socket
    end
  end

  @doc false
  @spec fetch_entry(Socket.t(), atom(), String.t()) :: {:ok, Entry.t()} | :error
  def fetch_entry(%Socket{} = socket, name, ref) when is_atom(name) and is_binary(ref) do
    with %{entries: entries} <- Map.get(upload_index(socket), name),
         %Entry{} = entry <- Map.get(entries, ref) do
      {:ok, entry}
    else
      _other -> :error
    end
  end

  @doc false
  @spec remove_entry(Socket.t(), atom(), String.t()) :: Socket.t()
  def remove_entry(%Socket{} = socket, name, ref) when is_atom(name) and is_binary(ref) do
    index = upload_index(socket)

    case Map.get(index, name) do
      %{entries: entries} = bucket ->
        next_entries = Map.delete(entries, ref)
        put_index(socket, Map.put(index, name, %{bucket | entries: next_entries}))

      _other ->
        socket
    end
  end

  @doc false
  @spec enqueue_op(Socket.t(), raw_op()) :: Socket.t()
  def enqueue_op(%Socket{} = socket, op) when is_map(op) do
    index = upload_index(socket)
    pending = Map.get(index, @pending_ops_key, [])
    put_index(socket, Map.put(index, @pending_ops_key, [op | pending]))
  end

  @doc false
  @spec enqueue_add(Socket.t(), atom(), Entry.t()) :: Socket.t()
  def enqueue_add(%Socket{} = socket, name, %Entry{} = entry) when is_atom(name) do
    enqueue_op(socket, %{
      op: "add",
      upload: Atom.to_string(name),
      ref: entry.ref,
      entry: Wire.to_wire(entry)
    })
  end

  @doc false
  @spec enqueue_progress(Socket.t(), atom(), String.t(), non_neg_integer()) :: Socket.t()
  def enqueue_progress(%Socket{} = socket, name, ref, progress)
      when is_atom(name) and is_binary(ref) and is_integer(progress) and progress >= 0 do
    enqueue_op(socket, %{
      op: "progress",
      upload: Atom.to_string(name),
      ref: ref,
      progress: progress
    })
  end

  @doc false
  @spec enqueue_complete(Socket.t(), atom(), String.t()) :: Socket.t()
  def enqueue_complete(%Socket{} = socket, name, ref) when is_atom(name) and is_binary(ref) do
    enqueue_op(socket, %{op: "complete", upload: Atom.to_string(name), ref: ref})
  end

  @doc false
  @spec enqueue_error(Socket.t(), atom(), String.t() | nil, Error.t()) :: Socket.t()
  def enqueue_error(%Socket{} = socket, name, ref, %Error{} = error) when is_atom(name) do
    base = %{op: "error", upload: Atom.to_string(name), error: Error.to_wire(error)}
    enqueue_op(socket, if(is_binary(ref), do: Map.put(base, :ref, ref), else: base))
  end

  @doc false
  @spec enqueue_cancel(Socket.t(), atom(), String.t()) :: Socket.t()
  def enqueue_cancel(%Socket{} = socket, name, ref) when is_atom(name) and is_binary(ref) do
    enqueue_op(socket, %{op: "cancel", upload: Atom.to_string(name), ref: ref})
  end

  # ---------------------------------------------------------------------------
  # Drain / flush
  # ---------------------------------------------------------------------------

  @doc """
  Pops pending ops from `socket.assigns.__uploads__.__pending_ops__`,
  coalesces consecutive progress ops for the same `{upload, ref}` to
  the latest progress, and returns `{ops, socket}` (newest at the end).

  Throttling is applied by `Musubi.Page.Server` at envelope-build time
  (per `{store_id, upload, ref}`); this drain only handles coalescing.
  """
  @spec flush_pending_ops(Socket.t()) :: {[raw_op()], Socket.t()}
  def flush_pending_ops(%Socket{} = socket) do
    case Map.fetch(socket.assigns, @assigns_key) do
      :error ->
        {[], socket}

      {:ok, index} ->
        raw = index |> Map.get(@pending_ops_key, []) |> Enum.reverse()
        coalesced = coalesce(raw)
        next_index = Map.put(index, @pending_ops_key, [])
        {coalesced, put_index(socket, next_index)}
    end
  end

  @doc """
  Returns the queued upload ops without flushing — useful for tests.
  """
  @spec pending_ops(Socket.t()) :: [raw_op()]
  def pending_ops(%Socket{} = socket) do
    upload_index(socket) |> Map.get(@pending_ops_key, []) |> Enum.reverse() |> coalesce()
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp upload_index(%Socket{assigns: assigns}), do: Map.get(assigns, @assigns_key, %{})

  defp put_index(%Socket{} = socket, index) do
    %{socket | assigns: Map.put(socket.assigns, @assigns_key, index)}
  end

  defp seen_configs(%Socket{} = socket) do
    Map.get(upload_index(socket), @seen_config_key, MapSet.new())
  end

  defp mark_seen(%Socket{} = socket, name) do
    index = upload_index(socket)
    next = Map.put(index, @seen_config_key, MapSet.put(seen_configs(socket), name))
    put_index(socket, next)
  end

  defp consume_meta(%Entry{mode: :channel, path: path}), do: %{path: path}
  defp consume_meta(%Entry{mode: :external, external_meta: meta}), do: %{external: meta}

  defp maybe_emit_reset({%Socket{} = socket, results}, name) do
    index = upload_index(socket)

    case Map.get(index, name) do
      %{entries: entries} when map_size(entries) == 0 ->
        {enqueue_op(socket, %{op: "reset", upload: Atom.to_string(name)}), results}

      _other ->
        {socket, results}
    end
  end

  defp coalesce(ops) when is_list(ops) do
    ops
    |> Enum.reduce({[], %{}}, fn op, {acc, last_progress_idx} ->
      case op do
        %{op: "progress", upload: upload, ref: ref} ->
          key = {upload, ref}

          case Map.fetch(last_progress_idx, key) do
            {:ok, idx} ->
              acc = List.replace_at(acc, idx, op)
              {acc, last_progress_idx}

            :error ->
              new_idx = length(acc)
              {acc ++ [op], Map.put(last_progress_idx, key, new_idx)}
          end

        _other ->
          # Non-progress ops break the coalescing run for this entry.
          {acc ++ [op], %{}}
      end
    end)
    |> elem(0)
  end
end
