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
    check? = opts[:check] == true

    cond do
      empty_bundle?(contents) ->
        # No eligible modules: don't write (or require) a stub bundle file.
        write_manifest!(output_path)
        :noop

      File.read(output_path) == {:ok, contents} ->
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
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&beam_to_module/1)
    |> Enum.filter(fn module ->
      TypeScript.eligible?(module) and not test_support_module?(module)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Beam files compiled by the project translate to atoms that are guaranteed
  # to exist by the time we scan, but third-party noise (e.g. half-stripped
  # beams from earlier toolchain runs) may not — guard with `to_existing_atom`
  # so we never mint unrelated atoms at runtime.
  defp beam_to_module(beam_path) do
    name = Path.basename(beam_path, ".beam")

    try do
      [String.to_existing_atom(name)]
    rescue
      ArgumentError -> []
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

  # The renderer always emits the header + AsyncResult preamble, even when no
  # modules are eligible. Treat that case as "nothing to write" so consumer
  # apps without any Arbor modules don't have to commit a file just to satisfy
  # the compiler.
  defp empty_bundle?(contents) do
    not String.contains?(contents, "export namespace ")
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
