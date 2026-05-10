defmodule Arbor.Page.StoreRegistry do
  @moduledoc "Runtime-internal registry for mounted Arbor store nodes, keyed by `store_id`."

  use TypedStructor

  alias Arbor.Page.StoreRegistry.Entry
  alias Arbor.Socket

  @typedoc "Runtime identity of a store node — array of local ids from root. Same shape as `Arbor.Socket.store_id/1`."
  @type identity_key() :: Socket.store_id()

  typed_structor do
    field :entries, %{optional(identity_key()) => Entry.t()},
      default: %{},
      doc:
        "Map of `store_id` (path of local ids) to mounted store node entries. The store `module` is metadata on each entry, not part of the key. Updated after each render+reconcile cycle and consulted by the command router."
  end

  @doc """
  Builds an empty store registry.

  ## Examples

      iex> Arbor.Page.StoreRegistry.new()
      %Arbor.Page.StoreRegistry{entries: %{}}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Stores one mounted node entry under its `store_id`.

  ## Examples

      iex> entry = %Arbor.Page.StoreRegistry.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> registry = Arbor.Page.StoreRegistry.put(Arbor.Page.StoreRegistry.new(), [], entry)
      iex> match?(%Arbor.Page.StoreRegistry{}, registry)
      true
  """
  @spec put(t(), identity_key(), Entry.t()) :: t()
  def put(%__MODULE__{entries: entries} = registry, store_id, %Entry{} = entry)
      when is_list(store_id) do
    %{registry | entries: Map.put(entries, store_id, entry)}
  end

  @doc """
  Looks up one mounted node entry by `store_id`.

  ## Examples

      iex> entry = %Arbor.Page.StoreRegistry.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> registry = Arbor.Page.StoreRegistry.put(Arbor.Page.StoreRegistry.new(), [], entry)
      iex> Arbor.Page.StoreRegistry.get(registry, [])
      entry
  """
  @spec get(t(), identity_key()) :: Entry.t() | nil
  def get(%__MODULE__{entries: entries}, store_id) when is_list(store_id) do
    Map.get(entries, store_id)
  end

  @doc """
  Deletes one mounted node entry by `store_id`.

  ## Examples

      iex> entry = %Arbor.Page.StoreRegistry.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> registry = Arbor.Page.StoreRegistry.put(Arbor.Page.StoreRegistry.new(), [], entry)
      iex> registry = Arbor.Page.StoreRegistry.delete(registry, [])
      iex> Arbor.Page.StoreRegistry.get(registry, [])
      nil
  """
  @spec delete(t(), identity_key()) :: t()
  def delete(%__MODULE__{entries: entries} = registry, store_id) when is_list(store_id) do
    %{registry | entries: Map.delete(entries, store_id)}
  end

  @doc """
  Returns every `store_id` currently stored in the registry.

  ## Examples

      iex> entry = %Arbor.Page.StoreRegistry.Entry{socket: %Arbor.Socket{}, module: Example}
      iex> registry = Arbor.Page.StoreRegistry.put(Arbor.Page.StoreRegistry.new(), [], entry)
      iex> Arbor.Page.StoreRegistry.keys(registry)
      [[]]
  """
  @spec keys(t()) :: [identity_key()]
  def keys(%__MODULE__{entries: entries}), do: Map.keys(entries)
end
