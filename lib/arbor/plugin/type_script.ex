defmodule Arbor.Plugin.TypeScript do
  @moduledoc """
  TypedStructor plugin that marks an Arbor `state do` block as eligible for
  TypeScript codegen and snapshots the normalized field metadata onto a
  persisted module attribute so the `mix arbor.codegen.ts` task can locate
  every TS-eligible Arbor module from a freshly-loaded application without
  re-walking the typed_structor AST.

  The actual TypeScript rendering lives in `Arbor.Codegen.TypeScript`. This
  plugin is wired into the typed_structor block built by `Arbor.DSL.State.state/1`.
  """

  use TypedStructor.Plugin

  @impl TypedStructor.Plugin
  @spec init(keyword()) :: :ok
  defmacro init(_opts), do: :ok

  @impl TypedStructor.Plugin
  defmacro after_definition(definition, _opts) do
    quote bind_quoted: [definition: definition] do
      Module.register_attribute(__MODULE__, :__arbor_ts__, persist: true)

      @__arbor_ts__ %{
        fields: Arbor.Plugin.Normalize.fields(definition.fields)
      }
    end
  end
end
