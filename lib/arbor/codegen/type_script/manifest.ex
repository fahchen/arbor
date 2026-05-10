defmodule Arbor.Codegen.TypeScript.Manifest do
  @moduledoc false
  # Per-module compile-time manifest for the `:arbor_ts` Mix compiler.
  #
  # The pattern mirrors `Phoenix.LiveView.ColocatedJS`: every Arbor `state do`
  # module gets its own subdirectory under `Mix.Project.build_path()`, and
  # `Mix.Tasks.Compile.ArborTs` discovers eligible modules by listing those
  # subdirectories — no beam scan, no `:application.get_key/2` walk.
  #
  # Layout:
  #
  #     <build>/arbor-codegen-ts/<inspect(module)>/state.term
  #
  # Each `state.term` is `:erlang.term_to_binary(%{module, fields, commands,
  # source})`. The `module` atom inside the term is the canonical reference;
  # the directory name is purely organizational so consumers can `mix clean`.
  #
  # `__after_compile__/2` is registered by `Arbor.Plugin.TypeScript` on every
  # `state do` module and runs at the tail of that module's compilation,
  # serializing the data the codegen renderer needs. Modules whose source
  # lives under `test/` are skipped so test fixtures don't pollute the bundle.

  @subdir "arbor-codegen-ts"

  @type entry() :: {module(), %{fields: list(), commands: list()}}

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok
  def __after_compile__(env, _bytecode) do
    if eligible_source?(env.file) do
      stamp(env.module, env.file, target_dir())
    end

    :ok
  end

  @doc false
  @spec stamp(module(), Path.t(), Path.t()) :: :ok
  def stamp(module, source_file, target) do
    File.mkdir_p!(module_dir(module, target))

    data = %{
      module: module,
      source: source_file,
      fields: List.wrap(module.__arbor__(:fields)),
      commands: List.wrap(module.__arbor__(:commands))
    }

    File.write!(state_path(module, target), :erlang.term_to_binary(data))
    :ok
  end

  @doc """
  Lists every stamped module's `{module, %{fields, commands}}` entry under
  `target`. Skips entries whose module no longer loads (e.g. a `state do`
  module deleted from source between compiles — its dir lingers until
  `clean_outdated/1` or `mix clean`).
  """
  @spec list(Path.t()) :: [entry()]
  def list(target \\ target_dir()) do
    case File.ls(target) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&read_entry(&1, target))
        |> Enum.sort_by(fn {module, _data} -> Module.split(module) end)

      _other ->
        []
    end
  end

  @doc """
  Removes manifest subdirectories whose module is no longer loadable.
  """
  @spec clean_outdated(Path.t()) :: :ok
  def clean_outdated(target \\ target_dir()) do
    case File.ls(target) do
      {:ok, names} ->
        names
        |> Enum.filter(&File.dir?(Path.join(target, &1)))
        |> Enum.each(&maybe_remove_outdated(&1, target))

      _other ->
        :ok
    end

    :ok
  end

  defp maybe_remove_outdated(name, target) do
    dir = Path.join(target, name)

    if module_loadable?(name, target) do
      :ok
    else
      File.rm_rf!(dir)
    end
  end

  defp module_loadable?(name, target) do
    case read_module(name, target) do
      {:ok, module} -> Code.ensure_loaded?(module)
      :error -> false
    end
  end

  @doc false
  @spec target_dir() :: Path.t()
  def target_dir do
    # Tests scope an alternate target via `Process.put(:__arbor_ts_target_dir__, ...)`
    # so they can drive `__after_compile__/2` and the compiler's `list/0` /
    # `clean_outdated/0` against an isolated tmp dir without clobbering the
    # real `_build/<env>/arbor-codegen-ts/` tree. Production callers leave the
    # process dict untouched and fall through to `Mix.Project.build_path()`.
    Process.get(:__arbor_ts_target_dir__) || Path.join(Mix.Project.build_path(), @subdir)
  end

  defp module_dir(module, target), do: Path.join(target, inspect(module))
  defp state_path(module, target), do: Path.join(module_dir(module, target), "state.term")

  defp read_entry(name, target) do
    state_path = Path.join([target, name, "state.term"])

    with true <- File.dir?(Path.join(target, name)),
         {:ok, bin} <- File.read(state_path),
         %{module: module} = data <- safe_term(bin),
         true <- Code.ensure_loaded?(module) do
      [{module, Map.take(data, [:fields, :commands])}]
    else
      _failure -> []
    end
  end

  defp read_module(name, target) do
    case File.read(Path.join([target, name, "state.term"])) do
      {:ok, bin} ->
        case safe_term(bin) do
          %{module: module} -> {:ok, module}
          _other -> :error
        end

      _error ->
        :error
    end
  end

  defp safe_term(bin) do
    :erlang.binary_to_term(bin)
  rescue
    ArgumentError -> nil
  end

  defp eligible_source?(file) when is_binary(file) do
    not (String.contains?(file, "/test/support/") or String.contains?(file, "/test/"))
  end

  defp eligible_source?(_other), do: true
end
