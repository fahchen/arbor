defmodule Musubi.Page.StoreTable do
  @moduledoc "Runtime-internal table of mounted Musubi store nodes, keyed by `store_id`."

  use TypedStructor

  alias Musubi.Page.StoreTable.Entry
  alias Musubi.Socket

  @typedoc "Runtime identity of a store node — array of local ids from root. Same shape as `Musubi.Socket.store_id/1`."
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

      iex> Musubi.Page.StoreTable.new()
      %Musubi.Page.StoreTable{entries: %{}}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Stores one mounted node entry under its `store_id`.

  ## Examples

      iex> entry = %Musubi.Page.StoreTable.Entry{socket: %Musubi.Socket{}, module: Example}
      iex> table = Musubi.Page.StoreTable.put(Musubi.Page.StoreTable.new(), [], entry)
      iex> match?(%Musubi.Page.StoreTable{}, table)
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

      iex> entry = %Musubi.Page.StoreTable.Entry{socket: %Musubi.Socket{}, module: Example}
      iex> table = Musubi.Page.StoreTable.put(Musubi.Page.StoreTable.new(), [], entry)
      iex> Musubi.Page.StoreTable.get(table, [])
      entry
  """
  @spec get(t(), key()) :: Entry.t() | nil
  def get(%__MODULE__{entries: entries}, store_id) when is_list(store_id) do
    Map.get(entries, store_id)
  end

  @doc """
  Deletes one mounted node entry by `store_id`.

  ## Examples

      iex> entry = %Musubi.Page.StoreTable.Entry{socket: %Musubi.Socket{}, module: Example}
      iex> table = Musubi.Page.StoreTable.put(Musubi.Page.StoreTable.new(), [], entry)
      iex> table = Musubi.Page.StoreTable.delete(table, [])
      iex> Musubi.Page.StoreTable.get(table, [])
      nil
  """
  @spec delete(t(), key()) :: t()
  def delete(%__MODULE__{entries: entries} = table, store_id) when is_list(store_id) do
    %{table | entries: Map.delete(entries, store_id)}
  end

  @doc """
  Returns every `store_id` currently stored in the table.

  ## Examples

      iex> entry = %Musubi.Page.StoreTable.Entry{socket: %Musubi.Socket{}, module: Example}
      iex> table = Musubi.Page.StoreTable.put(Musubi.Page.StoreTable.new(), [], entry)
      iex> Musubi.Page.StoreTable.keys(table)
      [[]]
  """
  @spec keys(t()) :: [key()]
  def keys(%__MODULE__{entries: entries}), do: Map.keys(entries)

  @doc """
  Returns every `store_id` in the subtree rooted at `prefix`, including `prefix`.

  ## Examples

      iex> entry = %Musubi.Page.StoreTable.Entry{socket: %Musubi.Socket{}, module: Example}
      iex> table =
      ...>   Musubi.Page.StoreTable.new()
      ...>   |> Musubi.Page.StoreTable.put(["mid"], entry)
      ...>   |> Musubi.Page.StoreTable.put(["mid", "leaf"], entry)
      ...>   |> Musubi.Page.StoreTable.put(["other"], entry)
      iex> Musubi.Page.StoreTable.subtree_keys(table, ["mid"]) |> Enum.sort()
      [["mid"], ["mid", "leaf"]]
  """
  @spec subtree_keys(t(), key()) :: [key()]
  def subtree_keys(%__MODULE__{} = table, prefix) when is_list(prefix) do
    table
    |> keys()
    |> Enum.filter(&List.starts_with?(&1, prefix))
  end
end
