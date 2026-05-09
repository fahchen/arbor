defmodule Arbor.Plugin.CommandPayload do
  @moduledoc false

  use TypedStructor.Plugin

  @impl TypedStructor.Plugin
  defmacro after_definition(definition, opts) do
    quote bind_quoted: [definition: definition, opts: opts] do
      command_name = Keyword.fetch!(opts, :command_name)
      owner_module = Keyword.fetch!(opts, :owner_module)
      payload_fields = Arbor.Plugin.Normalize.fields(definition.fields)

      Module.put_attribute(owner_module, :__arbor_commands__, %{
        name: command_name,
        payload_fields: payload_fields,
        opts: []
      })
    end
  end
end
