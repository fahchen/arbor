defmodule Arbor.Page.StoreRegistry do
  @moduledoc "Runtime-internal registry for mounted Arbor store nodes."

  use TypedStructor

  alias Arbor.Page.StoreRegistry.Entry

  @type identity_key :: {[atom() | String.t()], module(), String.t()}

  typed_structor do
    field :entries, %{optional(identity_key()) => Entry.t()},
      default: %{},
      doc:
        "Map of identity tuples `{parent_path, module, id}` to mounted store node entries. Updated after each render+reconcile cycle and consulted for command path resolution."
  end

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec put(t(), [atom() | String.t()], module(), String.t(), Entry.t()) :: t()
  def put(%__MODULE__{entries: entries} = registry, parent_path, module, id, %Entry{} = entry)
      when is_list(parent_path) and is_atom(module) and is_binary(id) do
    %{registry | entries: Map.put(entries, {parent_path, module, id}, entry)}
  end

  @spec get(t(), [atom() | String.t()], module(), String.t()) :: Entry.t() | nil
  def get(%__MODULE__{entries: entries}, parent_path, module, id)
      when is_list(parent_path) and is_atom(module) and is_binary(id) do
    Map.get(entries, {parent_path, module, id})
  end

  @spec delete(t(), [atom() | String.t()], module(), String.t()) :: t()
  def delete(%__MODULE__{entries: entries} = registry, parent_path, module, id)
      when is_list(parent_path) and is_atom(module) and is_binary(id) do
    %{registry | entries: Map.delete(entries, {parent_path, module, id})}
  end

  @spec keys(t()) :: [identity_key()]
  def keys(%__MODULE__{entries: entries}), do: Map.keys(entries)

  @spec path_lookup(t(), [String.t()]) :: Entry.t() | nil
  def path_lookup(%__MODULE__{entries: entries}, path) when is_list(path) do
    Enum.find_value(entries, fn {{parent_path, _module, id}, entry} ->
      if entry_path(parent_path, id) == path, do: entry
    end)
  end

  @spec entry_path([atom() | String.t()], String.t()) :: [String.t()]
  defp entry_path([], ""), do: []

  defp entry_path(parent_path, id) do
    parent_path
    |> Enum.map(&to_string/1)
    |> Enum.reverse()
    |> then(&Enum.reverse([id | &1]))
  end
end
