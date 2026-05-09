defmodule Mix.Tasks.Arbor.Codegen.Ts do
  @shortdoc "Generates TypeScript types for every Arbor `state do` module"

  @moduledoc """
  Walks every loaded Arbor `state do` module and emits a `.ts` file per
  module under the configured codegen output path.

  ## Usage

      mix arbor.codegen.ts            # write generated TS to disk
      mix arbor.codegen.ts --check    # exit non-zero if any file would change

  ## Configuration

  The output directory is `priv/codegen/ts/` by default and configurable via:

      config :arbor, :ts_codegen_output_path, "priv/codegen/ts"

  ## Eligibility

  A module is included when it `use`s `Arbor.Store` or `Arbor.State` — the
  TypedStructor `Arbor.Plugin.TypeScript` plugin marks the beam with a
  persisted `:__arbor_ts__` attribute that this task scans for.

  ## Output

  Each module produces one `.ts` file named after its TypeScript alias
  (`TypespecProbe` ⟶ `TypespecProbeState.ts`). Each file embeds the
  `AsyncResult<T>` generic so individual files can be consumed standalone.
  """

  use Mix.Task

  alias Arbor.Codegen.TypeScript

  @default_output_path "priv/codegen/ts"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [check: :boolean, output: :string])

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    output_path = Keyword.get(opts, :output) || configured_output_path()
    File.mkdir_p!(output_path)

    rendered = render_all_modules()

    if opts[:check] do
      check_against_disk!(rendered, output_path)
    else
      write_to_disk!(rendered, output_path)
    end
  end

  @doc false
  @spec render_all_modules() :: [TypeScript.rendered()]
  def render_all_modules do
    eligible_modules()
    |> Enum.map(&TypeScript.render/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.path)
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

  # Modules compiled from `test/support/*.ex` end up in the .app file when the
  # task runs under `MIX_ENV=test`. They should never produce committed TS
  # artifacts. Detect them by their compile source path.
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

  # Resolve the current Mix project's app modules from the .app file.
  # Restricting to the current app keeps test-support fixtures and
  # third-party Arbor stores out of the consumer's codegen output.
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

  defp write_to_disk!(rendered, output_path) do
    Enum.each(rendered, fn %{path: path, contents: contents} ->
      target = Path.join(output_path, path)
      File.write!(target, contents)
      Mix.shell().info("wrote #{target}")
    end)

    :ok
  end

  defp check_against_disk!(rendered, output_path) do
    issues = collect_diffs(rendered, output_path) ++ collect_stale(rendered, output_path)

    case issues do
      [] ->
        Mix.shell().info("arbor.codegen.ts: #{length(rendered)} modules — no drift")
        :ok

      _issues ->
        Enum.each(issues, &log_issue/1)

        Mix.raise(
          "arbor.codegen.ts.check failed: TypeScript artifacts are out of date. " <>
            "Run `mix arbor.codegen.ts` and commit the result."
        )
    end
  end

  defp collect_diffs(rendered, output_path) do
    Enum.flat_map(rendered, fn %{path: path, contents: contents} ->
      target = Path.join(output_path, path)

      case File.read(target) do
        {:ok, ^contents} -> []
        {:ok, _other} -> [{:changed, target}]
        {:error, :enoent} -> [{:missing, target}]
        {:error, reason} -> [{:error, target, reason}]
      end
    end)
  end

  defp collect_stale(rendered, output_path) do
    case File.ls(output_path) do
      {:ok, files} ->
        generated_names = MapSet.new(rendered, & &1.path)

        files
        |> Enum.filter(fn name ->
          String.ends_with?(name, ".ts") and not MapSet.member?(generated_names, name)
        end)
        |> Enum.map(&{:stale, Path.join(output_path, &1)})

      {:error, :enoent} ->
        []
    end
  end

  defp log_issue({:changed, path}), do: Mix.shell().error("changed: #{path}")
  defp log_issue({:missing, path}), do: Mix.shell().error("missing: #{path}")
  defp log_issue({:stale, path}), do: Mix.shell().error("stale (no longer generated): #{path}")

  defp log_issue({:error, path, reason}),
    do: Mix.shell().error("error reading #{path}: #{inspect(reason)}")
end
