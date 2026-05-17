defmodule Musubi.Plugin.TypeSpec do
  @moduledoc false

  use TypedStructor.Plugin

  @impl TypedStructor.Plugin
  defmacro after_definition(definition, _opts) do
    quote bind_quoted: [definition: definition] do
      @type stream(item) :: [item]
      @type state() :: t()

      require TypedStructor.Definer.Defstruct
      TypedStructor.Definer.Defstruct.__type_ast__(definition)
    end
  end
end
