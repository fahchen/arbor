defmodule Musubi.Plugin.TypeScript do
  @moduledoc """
  TypedStructor plugin that marks an Musubi `state do` block as eligible for
  TypeScript codegen.

  The plugin injects an `@after_compile` callback pointing at
  `Musubi.Codegen.TypeScript.Manifest`, which serializes the field and command
  reflection into a per-module manifest entry under
  `Mix.Project.build_path()/musubi-codegen-ts/`. The `:musubi_ts` Mix compiler
  then discovers eligible modules by listing those entries — there is no beam
  scan or `:application.get_key/2` walk.

  The actual TypeScript rendering lives in `Musubi.Codegen.TypeScript`. This
  plugin is wired into the typed_structor block built by `Musubi.DSL.State.state/1`.
  """

  use TypedStructor.Plugin

  @impl TypedStructor.Plugin
  @spec init(keyword()) :: :ok
  defmacro init(_opts), do: :ok

  @impl TypedStructor.Plugin
  defmacro after_definition(_definition, _opts) do
    quote do
      @after_compile {Musubi.Codegen.TypeScript.Manifest, :__after_compile__}
    end
  end
end
