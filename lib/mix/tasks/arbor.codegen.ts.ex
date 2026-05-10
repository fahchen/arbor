defmodule Mix.Tasks.Arbor.Codegen.Ts do
  @shortdoc "Generates a single TypeScript bundle for every Arbor `state do` module"

  @moduledoc """
  Walks every Arbor `state do` module in the current Mix project and writes
  one TypeScript bundle file with namespaces mirroring the Elixir module tree.

  ## Usage

      mix arbor.codegen.ts            # write generated TS bundle to disk
      mix arbor.codegen.ts --check    # exit non-zero if the bundle would change

  ## Configuration

  Output path defaults to `priv/codegen/ts/arbor.ts` and is configurable:

      config :arbor, :ts_codegen_output_path, "priv/codegen/ts/arbor.ts"

  ## Eligibility

  A module is included when it `use`s `Arbor.Store` or `Arbor.State` — the
  TypedStructor `Arbor.Plugin.TypeScript` plugin marks the beam with a
  persisted `:__arbor_ts__` attribute that this task scans for. Modules
  whose compile source lives under `test/` (e.g. test/support fixtures) are
  filtered out.

  ## Output

  Single bundle file `priv/codegen/ts/arbor.ts` containing:

    * `export type AsyncResult<T>` (top-level)
    * `export namespace <Segment>` nesting per Elixir module path
    * `export type <LastSegment>` declared in the innermost matching namespace
    * for `Arbor.Store` modules with declared commands, an adjacent
      `export namespace <LastSegment> { export type Commands = ... }`
  """

  use Mix.Task

  alias Arbor.Codegen.TypeScript

  @default_output_path "priv/codegen/ts/arbor.ts"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [check: :boolean, output: :string])

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    output_path = Keyword.get(opts, :output) || configured_output_path()

    contents = render_bundle()

    if opts[:check] do
      check_against_disk!(contents, output_path)
    else
      write_to_disk!(contents, output_path)
    end
  end

  @doc false
  @spec render_bundle() :: String.t()
  def render_bundle do
    TypeScript.render(eligible_modules())
  end

  @doc false
  @spec eligible_modules() :: [module()]
  def eligible_modules do
    current_app_modules()
    |> Enum.filter(fn module ->
      TypeScript.eligible?(module) and not test_support_module?(module)
    end)
    |> Enum.uniq()
    |> Enum.sort()
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

  defp current_app_modules do
    case Keyword.get(Mix.Project.config(), :app) do
      nil ->
        []

      app ->
        Application.load(app)

        case :application.get_key(app, :modules) do
          {:ok, modules} -> modules
          :undefined -> []
        end
    end
  end

  defp configured_output_path do
    Application.get_env(:arbor, :ts_codegen_output_path, @default_output_path)
  end

  defp write_to_disk!(contents, output_path) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, contents)
    Mix.shell().info("wrote #{output_path}")
    :ok
  end

  defp check_against_disk!(contents, output_path) do
    case File.read(output_path) do
      {:ok, ^contents} ->
        Mix.shell().info("arbor.codegen.ts: #{output_path} — no drift")
        :ok

      {:ok, _other} ->
        Mix.shell().error("changed: #{output_path}")
        raise_drift()

      {:error, :enoent} ->
        # Empty bundle (no eligible modules) → no drift even if file is missing.
        if empty_bundle?(contents) do
          Mix.shell().info("arbor.codegen.ts: no eligible modules — nothing to write")
          :ok
        else
          Mix.shell().error("missing: #{output_path}")
          raise_drift()
        end

      {:error, reason} ->
        Mix.shell().error("error reading #{output_path}: #{inspect(reason)}")
        raise_drift()
    end
  end

  # The renderer always emits the header + AsyncResult preamble, even when no
  # modules are eligible. Treat that case as "nothing to write" so consumer
  # apps without any Arbor modules don't have to commit a file just to pass
  # `--check`.
  defp empty_bundle?(contents) do
    not String.contains?(contents, "export namespace ")
  end

  @spec raise_drift() :: no_return()
  defp raise_drift do
    Mix.raise(
      "arbor.codegen.ts.check failed: TypeScript bundle is out of date. " <>
        "Run `mix arbor.codegen.ts` and commit the result."
    )
  end
end
