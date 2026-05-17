defmodule Arbor.Page.StoreTable do
  @moduledoc "Runtime-internal table of mounted Arbor store nodes, keyed by `store_id`."

  use TypedStructor

  alias Arbor.Page.StoreTable.Entry
  alias Arbor.Socket

  @typedoc "Runtime identity of a store node — array of local ids from root. Same shape as `Arbor.Socket.store_id/1`."
  @type key() :: Socket.store_id()

  typed_structor do
    field :entries, %{optional(key()) => Entry.t()},
      default: %{},
      doc:
        "Map of `store_id` (path of local ids) to mounted store node entries. The store `module` is metadata on each entry, not part of the key. Updated after each render+reconcile cycle and consulted by the command router."
  end

  @doc """
  Builds an empty store table.

  ## Examples

      iex> Arbor.Page.StoreTable.new()
      %Arbor.Page.StoreTable{entries: %{}}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Stores one mounted node entry under its `store_id`.

  ## Examples

      iex> entry = %Arbor.Page.StoreTable.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> table = Arbor.Page.StoreTable.put(Arbor.Page.StoreTable.new(), [], entry)
      iex> match?(%Arbor.Page.StoreTable{}, table)
      true
  """
  @spec put(t(), key(), Entry.t()) :: t()
  def put(%__MODULE__{entries: entries} = table, store_id, %Entry{} = entry)
      when is_list(store_id) do
    %{table | entries: Map.put(entries, store_id, entry)}
  end

  @doc """
  Looks up one mounted node entry by `store_id`.

  ## Examples

      iex> entry = %Arbor.Page.StoreTable.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> table = Arbor.Page.StoreTable.put(Arbor.Page.StoreTable.new(), [], entry)
      iex> Arbor.Page.StoreTable.get(table, [])
      entry
  """
  @spec get(t(), key()) :: Entry.t() | nil
  def get(%__MODULE__{entries: entries}, store_id) when is_list(store_id) do
    Map.get(entries, store_id)
  end

  @doc """
  Deletes one mounted node entry by `store_id`.

  ## Examples

      iex> entry = %Arbor.Page.StoreTable.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> table = Arbor.Page.StoreTable.put(Arbor.Page.StoreTable.new(), [], entry)
      iex> table = Arbor.Page.StoreTable.delete(table, [])
      iex> Arbor.Page.StoreTable.get(table, [])
      nil
  """
  @spec delete(t(), key()) :: t()
  def delete(%__MODULE__{entries: entries} = table, store_id) when is_list(store_id) do
    %{table | entries: Map.delete(entries, store_id)}
  end

  @doc """
  Returns every `store_id` currently stored in the table.

  ## Examples

      iex> entry = %Arbor.Page.StoreTable.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> table = Arbor.Page.StoreTable.put(Arbor.Page.StoreTable.new(), [], entry)
      iex> Arbor.Page.StoreTable.keys(table)
      [[]]
  """
  @spec keys(t()) :: [key()]
  def keys(%__MODULE__{entries: entries}), do: Map.keys(entries)

  @doc """
  Returns every `store_id` in the subtree rooted at `prefix`, including `prefix`.

  ## Examples

      iex> entry = %Arbor.Page.StoreTable.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> table =
      ...>   Arbor.Page.StoreTable.new()
      ...>   |> Arbor.Page.StoreTable.put(["mid"], entry)
      ...>   |> Arbor.Page.StoreTable.put(["mid", "leaf"], entry)
      ...>   |> Arbor.Page.StoreTable.put(["other"], entry)
      iex> Arbor.Page.StoreTable.subtree_keys(table, ["mid"]) |> Enum.sort()
      [["mid"], ["mid", "leaf"]]
  """
  @spec subtree_keys(t(), key()) :: [key()]
  def subtree_keys(%__MODULE__{} = table, prefix) when is_list(prefix) do
    table
    |> keys()
    |> Enum.filter(&List.starts_with?(&1, prefix))
  end

  @doc """
  Returns every `store_id` whose subtree contains pending socket or stream mutations.

  The set includes the dirty store itself and each ancestor prefix so one resolve
  pass can answer subtree-dirty checks with constant-time membership tests.

  ## Examples

      iex> socket = Arbor.Socket.assign(%Arbor.Socket{}, :title, "after")
      iex> entry = %Arbor.Page.StoreTable.Entry{socket: socket, module: Example}
      iex> table =
      ...>   Arbor.Page.StoreTable.new()
      ...>   |> Arbor.Page.StoreTable.put(["mid", "leaf"], entry)
      iex> Arbor.Page.StoreTable.dirty_store_ids(table)
      MapSet.new([[], ["mid"], ["mid", "leaf"]])
  """
  @spec dirty_store_ids(t()) :: MapSet.t(key())
  def dirty_store_ids(%__MODULE__{} = table) do
    Enum.reduce(keys(table), MapSet.new(), fn store_id, acc ->
      case get(table, store_id) do
        %Entry{socket: %Socket{} = socket} ->
          maybe_put_dirty_store_id_prefixes(acc, store_id, socket)

        nil ->
          acc
      end
    end)
  end

  @spec socket_dirty?(Socket.t()) :: boolean()
  defp socket_dirty?(%Socket{} = socket) do
    Socket.any_changed?(socket) or stream_dirty?(socket)
  end

  @spec stream_dirty?(Socket.t()) :: boolean()
  defp stream_dirty?(%Socket{} = socket) do
    socket
    |> Arbor.Stream.changed_streams()
    |> MapSet.size() > 0
  end

  @spec maybe_put_dirty_store_id_prefixes(MapSet.t(key()), key(), Socket.t()) :: MapSet.t(key())
  defp maybe_put_dirty_store_id_prefixes(acc, store_id, %Socket{} = socket)
       when is_struct(acc, MapSet) and is_list(store_id) do
    if socket_dirty?(socket) do
      Enum.reduce(store_id_prefixes(store_id), acc, &MapSet.put(&2, &1))
    else
      acc
    end
  end

  @spec store_id_prefixes(key()) :: [key()]
  defp store_id_prefixes(store_id) when is_list(store_id) do
    for prefix_size <- 0..length(store_id) do
      Enum.take(store_id, prefix_size)
    end
  end
end
