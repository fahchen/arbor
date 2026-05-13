defmodule Mix.Tasks.Compile.ArborTs do
  @shortdoc "Renders the Arbor TypeScript bundle for every `state do` module"

  @moduledoc """
  Mix compiler that walks every Arbor `state do` module exposed by the
  current Mix project and writes one TypeScript bundle file with namespaces
  mirroring the Elixir module tree.

  ## Setup

  Add `:arbor_ts` to the project's compiler chain:

      def project do
        [
          ...,
          compilers: Mix.compilers() ++ [:arbor_ts]
        ]
      end

  Running `mix compile` then keeps the bundle in sync automatically. Invoke
  the compiler directly with `mix compile.arbor_ts` if you want to regenerate
  without a full project recompile.

  ## Options

    * `--check` — exit non-zero with a `Mix.Task.Compiler.Diagnostic` if the
      on-disk bundle differs from a freshly-rendered one. Wire this into a
      `precommit` / CI alias to gate drift:

          aliases: [
            precommit: ["compile --warnings-as-errors", "compile.arbor_ts --check", ...]
          ]

  ## Configuration

  Output path defaults to `priv/codegen/ts/arbor.ts`. Override per-app:

      config :arbor, :ts_codegen_output_path, "priv/codegen/ts/arbor.ts"

  ## Discovery

  Every Arbor `state do` module ends up with a manifest entry under
  `Mix.Project.build_path()/arbor-codegen-ts/<inspect(module)>/state.term`,
  stamped at module-compile time by `Arbor.Plugin.TypeScript`'s injected
  `@after_compile` callback. This compiler simply lists those entries —
  there is no beam scan or `:application.get_key/2` walk. Modules whose
  source lives under `test/` (e.g. `test/support/` fixtures) are skipped at
  stamp time so they never appear in the bundle.
  """

  use Mix.Task.Compiler

  alias Arbor.Codegen.TypeScript
  alias Arbor.Codegen.TypeScript.Manifest

  @compiler_name "arbor_ts"
  @default_output_path "priv/codegen/ts/arbor.d.ts"

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
    Application.get_env(:arbor, :ts_codegen_output_path, @default_output_path)
  end

  defp write_bundle!(contents, output_path) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, contents)
    Mix.shell().info("[arbor_ts] wrote #{output_path}")
  end

  defp drift_diagnostic(output_path) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: @compiler_name,
      file: output_path,
      message:
        "Arbor TypeScript bundle is out of date. Run `mix compile.arbor_ts` and commit the result.",
      position: nil,
      severity: :error
    }
  end
end
