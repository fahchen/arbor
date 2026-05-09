defmodule Arbor.Plugin.Definer do
  @moduledoc false

  alias TypedStructor.Definer.Utils

  @spec define(TypedStructor.Definition.t()) :: Macro.t()
  defmacro define(definition) do
    quote bind_quoted: [definition: definition] do
      if Keyword.get(definition.options, :define_struct, true) do
        {fields, enforce_keys} = Utils.fields_and_enforce_keys(definition)

        @enforce_keys Enum.reverse(enforce_keys)
        defstruct fields
      end
    end
  end
end
