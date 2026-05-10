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

  ## Eligibility

  A module is included when it `use`s `Arbor.Store` or `Arbor.State` — the
  TypedStructor `Arbor.Plugin.TypeScript` plugin marks the beam with a
  persisted `:__arbor_ts__` attribute that this compiler scans for. Modules
  whose compile source lives under `test/` (e.g. test/support fixtures) are
  filtered out.
  """

  use Mix.Task.Compiler

  alias Arbor.Codegen.TypeScript

  @compiler_name "arbor_ts"
  @manifest_filename "compile.arbor_ts"
  @default_output_path "priv/codegen/ts/arbor.ts"

  @impl Mix.Task.Compiler
  @spec run([String.t()]) ::
          :ok
          | :noop
          | {:ok, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:error, [Mix.Task.Compiler.Diagnostic.t()]}
  def run(argv), do: do_run(argv, eligible_modules(), configured_output_path())

  @doc false
  @spec do_run([String.t()], [module()], Path.t()) ::
          :noop
          | {:ok, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:error, [Mix.Task.Compiler.Diagnostic.t()]}
  def do_run(argv, modules, output_path) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean])

    contents = TypeScript.render(modules)
    existing = File.read(output_path)
    check? = opts[:check] == true

    cond do
      existing == {:ok, contents} ->
        write_manifest!(output_path)
        :noop

      modules == [] and existing == {:error, :enoent} ->
        # Fresh consumer project with no eligible modules — nothing to write.
        # Once the project gains a `state do` module, the next compile drops
        # into the write/check arms below and any pre-existing stale bundle
        # is detected as drift.
        write_manifest!(output_path)
        :noop

      check? ->
        {:error, [drift_diagnostic(output_path)]}

      true ->
        write_bundle!(contents, output_path)
        write_manifest!(output_path)
        {:ok, []}
    end
  end

  @impl Mix.Task.Compiler
  @spec manifests() :: [Path.t()]
  def manifests, do: [manifest_path()]

  @impl Mix.Task.Compiler
  @spec clean() :: :ok
  def clean do
    _ignore = File.rm(manifest_path())
    :ok
  end

  @doc false
  @spec eligible_modules() :: [module()]
  def eligible_modules do
    case Keyword.get(Mix.Project.config(), :app) do
      nil ->
        []

      app ->
        # `:app` compiler runs before `:arbor_ts` in the standard chain
        # (`Mix.compilers() ++ [:arbor_ts]`), so the loaded `.app` file is
        # fresh by the time we read its `:modules` key. Loading is idempotent.
        Application.load(app)

        case :application.get_key(app, :modules) do
          {:ok, modules} ->
            modules
            |> Enum.filter(&(TypeScript.eligible?(&1) and not test_support_module?(&1)))
            |> Enum.uniq()
            |> Enum.sort()

          :undefined ->
            []
        end
    end
  end

  defp test_support_module?(module) do
    case module.__info__(:compile) do
      info when is_list(info) ->
        case Keyword.get(info, :source) do
          nil ->
            false

          source ->
            source = List.to_string(source)
            String.contains?(source, "/test/support/") or String.contains?(source, "/test/")
        end

      _other ->
        false
    end
  end

  defp configured_output_path do
    Application.get_env(:arbor, :ts_codegen_output_path, @default_output_path)
  end

  defp write_bundle!(contents, output_path) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, contents)
    Mix.shell().info("[arbor_ts] wrote #{output_path}")
  end

  defp write_manifest!(output_path) do
    File.mkdir_p!(Mix.Project.manifest_path())
    File.write!(manifest_path(), :erlang.term_to_binary(%{output_path: output_path}))
  end

  defp manifest_path, do: Path.join(Mix.Project.manifest_path(), @manifest_filename)

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
