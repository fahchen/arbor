defmodule Mix.Tasks.Compile.MusubiTs do
  @shortdoc "Renders the Musubi TypeScript bundle for every `state do` module"

  @moduledoc """
  Mix compiler that walks every Musubi `state do` module exposed by the
  current Mix project and writes one TypeScript bundle file with namespaces
  mirroring the Elixir module tree.

  ## Setup

  Add `:musubi_ts` to the project's compiler chain:

      def project do
        [
          ...,
          compilers: Mix.compilers() ++ [:musubi_ts]
        ]
      end

  Running `mix compile` then keeps the bundle in sync automatically. Invoke
  the compiler directly with `mix compile.musubi_ts` if you want to regenerate
  without a full project recompile.

  ## Options

    * `--check` — exit non-zero with a `Mix.Task.Compiler.Diagnostic` if the
      on-disk bundle differs from a freshly-rendered one. Wire this into a
      `precommit` / CI alias to gate drift:

          aliases: [
            precommit: ["compile --warnings-as-errors", "compile.musubi_ts --check", ...]
          ]

  ## Configuration

  Output path defaults to `priv/codegen/ts/musubi.ts`. Override per-app:

      config :musubi, :ts_codegen_output_path, "priv/codegen/ts/musubi.ts"

  ## Discovery

  Every Musubi `state do` module ends up with a manifest entry under
  `Mix.Project.build_path()/musubi-codegen-ts/<inspect(module)>/state.term`,
  stamped at module-compile time by `Musubi.Plugin.TypeScript`'s injected
  `@after_compile` callback. This compiler simply lists those entries —
  there is no beam scan or `:application.get_key/2` walk. Modules whose
  source lives under `test/` (e.g. `test/support/` fixtures) are skipped at
  stamp time so they never appear in the bundle.
  """

  use Mix.Task.Compiler

  alias Musubi.Codegen.TypeScript
  alias Musubi.Codegen.TypeScript.Manifest

  @compiler_name "musubi_ts"
  @default_output_path "priv/codegen/ts/musubi.d.ts"

  @impl Mix.Task.Compiler
  @spec run([String.t()]) ::
          :ok
          | :noop
          | {:ok, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:error, [Mix.Task.Compiler.Diagnostic.t()]}
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean])

    Manifest.clean_outdated()

    entries = Manifest.list()
    output_path = configured_output_path()
    contents = TypeScript.render(entries)
    existing = File.read(output_path)
    check? = opts[:check] == true

    cond do
      existing == {:ok, contents} ->
        :noop

      entries == [] and existing == {:error, :enoent} ->
        :noop

      check? ->
        {:error, [drift_diagnostic(output_path)]}

      true ->
        write_bundle!(contents, output_path)
        {:ok, []}
    end
  end

  @impl Mix.Task.Compiler
  @spec manifests() :: [Path.t()]
  def manifests, do: [Manifest.target_dir()]

  @impl Mix.Task.Compiler
  @spec clean() :: :ok
  def clean do
    _ignore = File.rm_rf(Manifest.target_dir())
    :ok
  end

  defp configured_output_path do
    Application.get_env(:musubi, :ts_codegen_output_path, @default_output_path)
  end

  defp write_bundle!(contents, output_path) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, contents)
    Mix.shell().info("[musubi_ts] wrote #{output_path}")
  end

  defp drift_diagnostic(output_path) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: @compiler_name,
      file: output_path,
      message:
        "Musubi TypeScript bundle is out of date. Run `mix compile.musubi_ts` and commit the result.",
      position: nil,
      severity: :error
    }
  end
end
