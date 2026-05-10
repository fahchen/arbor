defmodule Arbor.Plugin.TypeScript do
  @moduledoc """
  TypedStructor plugin that marks an Arbor `state do` block as eligible for
  TypeScript codegen.

  The plugin injects an `@after_compile` callback pointing at
  `Arbor.Codegen.TypeScript.Manifest`, which serializes the field and command
  reflection into a per-module manifest entry under
  `Mix.Project.build_path()/arbor-codegen-ts/`. The `:arbor_ts` Mix compiler
  then discovers eligible modules by listing those entries — there is no beam
  scan or `:application.get_key/2` walk.

  The actual TypeScript rendering lives in `Arbor.Codegen.TypeScript`. This
  plugin is wired into the typed_structor block built by `Arbor.DSL.State.state/1`.
  """

  use TypedStructor.Plugin

  @impl TypedStructor.Plugin
  @spec init(keyword()) :: :ok
  defmacro init(_opts), do: :ok

  @impl TypedStructor.Plugin
  defmacro after_definition(_definition, _opts) do
    quote do
      @after_compile {Arbor.Codegen.TypeScript.Manifest, :__after_compile__}
    end
  end
end
