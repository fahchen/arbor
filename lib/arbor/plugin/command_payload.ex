defmodule Arbor.Plugin.CommandPayload do
  @moduledoc false

  @type field_definition :: %{name: atom(), type: Macro.t(), opts: keyword()}

  @spec normalize_fields([Keyword.t()]) :: [field_definition()]
  def normalize_fields(fields) do
    Enum.map(fields, fn field ->
      %{
        name: Keyword.fetch!(field, :name),
        type: Keyword.fetch!(field, :type),
        opts: Keyword.drop(field, [:name, :type])
      }
    end)
  end
end
