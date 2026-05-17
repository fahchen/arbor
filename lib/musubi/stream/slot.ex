defmodule Musubi.Stream.Slot do
  @moduledoc """
  Per-stream pending-ops struct held under `socket.assigns.__streams__`.

    * `inserts` and `deletes` queue the deltas applied to a stream during a
      cycle. The server **never** materializes the stream — the client owns
      that. Each cycle's pending ops drain into the patch envelope's
      `stream_ops`.
    * `prune/1` clears `inserts`/`deletes`/`reset?` and is invoked once the
      ops are flushed. Configuration (`name`, `item_key_fun`, `ref`) survives.
    * `reset?` is set when the application calls `Musubi.Stream.stream/4` with
      `reset: true`. Drains emit a `reset` wire op ahead of the inserts so
      the client clears its local stream first.
  """

  use TypedStructor

  @typedoc "Insert entry queued for the current cycle: `{item_key, at, item, limit}`."
  @type insert_entry() :: {String.t(), integer(), term(), integer() | nil}

  @typedoc "Delete entry queued for the current cycle (item_key)."
  @type delete_entry() :: String.t()

  typed_structor do
    field :name, atom(),
      enforce: true,
      doc: "Stream identifier matching a `stream :name, T, opts` declaration."

    field :item_key_fun, (term() -> String.t()),
      enforce: true,
      doc: "Function returning a binary key for each item."

    field :ref, non_neg_integer(),
      enforce: true,
      doc:
        "Per-stream unique ref used in wire ops to disambiguate. Stable across the stream's lifetime. Encoded as a string in wire ops."

    field :inserts, [insert_entry()],
      default: [],
      doc:
        "Pending inserts to flush this cycle: `[{item_key, at, item, limit}, ...]`. Stored newest-first for O(1) prepend; flushed in reverse so the wire op array is queue order."

    field :deletes, [delete_entry()],
      default: [],
      doc:
        "Pending deletes to flush this cycle: `[item_key, ...]`. Stored newest-first; flushed in reverse so the wire op array is queue order."

    field :reset?, boolean(),
      default: false,
      doc: "Whether the next flush should clear the client's local stream first."
  end

  @doc """
  Returns a pruned copy of `slot` with all pending fields cleared.

  Configuration fields (`name`, `item_key_fun`, `ref`) are preserved.

  ## Examples

      iex> slot = %Musubi.Stream.Slot{
      ...>   name: :songs,
      ...>   item_key_fun: fn item -> "songs-" <> item.id end,
      ...>   ref: 0,
      ...>   inserts: [{"songs-1", -1, %{id: "1"}, nil}],
      ...>   deletes: ["songs-2"],
      ...>   reset?: true
      ...> }
      iex> pruned = Musubi.Stream.Slot.prune(slot)
      iex> {pruned.inserts, pruned.deletes, pruned.reset?}
      {[], [], false}
      iex> pruned.name
      :songs
  """
  @spec prune(t()) :: t()
  def prune(%__MODULE__{} = slot) do
    %{slot | inserts: [], deletes: [], reset?: false}
  end
end
