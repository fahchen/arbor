defmodule Musubi.Plugin.Normalize do
  @moduledoc false

  @type field_definition() :: %{name: atom(), type: Macro.t(), opts: keyword()}

  @doc """
  Normalizes typed_structor's keyword-list field representation into the
  `%{name, type, opts}` map shape used by Musubi reflection.

  ## Examples

      iex> Musubi.Plugin.Normalize.fields([[name: :title, type: {:__aliases__, [], [:String]}, required: true]])
      [%{name: :title, type: {:__aliases__, [], [:String]}, opts: [required: true]}]
  """
  @spec fields([Keyword.t()]) :: [field_definition()]
  def fields(fields) do
    Enum.map(fields, fn field ->
      %{
        name: Keyword.fetch!(field, :name),
        type: Keyword.fetch!(field, :type),
        opts: Keyword.drop(field, [:name, :type])
      }
    end)
  end
end
