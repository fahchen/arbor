defmodule Mix.Tasks.Compile.ArborTsTest do
  # async: false because the test scopes a manifest target_dir override via
  # Process dict and writes the rendered bundle to the configured
  # `:ts_codegen_output_path` (which `config/test.exs` points at
  # `test/tmp/arbor_ts_bundle.ts`). Concurrent runs would race on that path.
  use ExUnit.Case, async: false

  alias Arbor.Codegen.TypeScript.Manifest
  alias Arbor.TestSupport.TypespecProbe
  alias Arbor.TestSupport.TypespecProbeChild
  alias Mix.Tasks.Compile.ArborTs

  setup do
    target =
      Path.join(
        System.tmp_dir!(),
        "arbor_ts_compile_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(target)
    Process.put(:__arbor_ts_target_dir__, target)

    output_path = Application.fetch_env!(:arbor, :ts_codegen_output_path)
    File.mkdir_p!(Path.dirname(output_path))
    File.rm(output_path)

    on_exit(fn ->
      File.rm_rf!(target)
      File.rm(output_path)
    end)

    {:ok, target: target, output_path: output_path}
  end

  describe "run/1 — empty manifest" do
    test "returns :noop and does not create the bundle file", %{output_path: output_path} do
      assert ArborTs.run([]) == :noop
      refute File.exists?(output_path)
    end

    test "returns :noop in --check mode", %{output_path: output_path} do
      assert ArborTs.run(["--check"]) == :noop
      refute File.exists?(output_path)
    end
  end

  describe "run/1 — populated manifest" do
    setup %{target: target} do
      Manifest.stamp(TypespecProbe, "lib/x.ex", target)
      Manifest.stamp(TypespecProbeChild, "lib/y.ex", target)
      :ok
    end

    test "writes a fresh bundle covering every stamped module", %{output_path: output_path} do
      assert {:ok, []} = ArborTs.run([])

      contents = File.read!(output_path)
      assert contents =~ "declare global {"
      assert contents =~ "type AsyncResult<T>"
      assert contents =~ "interface StoreDef<Module extends string, Shape, Commands>"
      refute contents =~ ~s|import "@arbor/client"|
      assert contents =~ ~s|"Arbor.TestSupport.TypespecProbe": StoreDef<|
      assert contents =~ ~s|"Arbor.TestSupport.TypespecProbeChild": StoreDef<|
      assert contents =~ "Arbor.StreamField<"
      assert contents =~ "Arbor.AsyncField<"
      assert String.ends_with?(contents, "export {}\n")
    end

    test "returns :noop when the bundle already matches", %{output_path: output_path} do
      assert {:ok, []} = ArborTs.run([])
      assert ArborTs.run([]) == :noop
      assert File.exists?(output_path)
    end

    test "rewrites a stale bundle", %{output_path: output_path} do
      File.write!(output_path, "// stale\n")
      assert {:ok, []} = ArborTs.run([])

      assert File.read!(output_path) =~
               ~s|"Arbor.TestSupport.TypespecProbe": StoreDef<|
    end

    test "--check returns drift diagnostic on mismatch and does not write",
         %{output_path: output_path} do
      File.write!(output_path, "// stale\n")

      assert {:error, [diagnostic]} = ArborTs.run(["--check"])
      assert diagnostic.severity == :error
      assert diagnostic.compiler_name == "arbor_ts"
      assert diagnostic.file == output_path
      assert File.read!(output_path) == "// stale\n"
    end

    test "--check returns :noop when bundle matches", %{output_path: output_path} do
      assert {:ok, []} = ArborTs.run([])
      assert ArborTs.run(["--check"]) == :noop
      assert File.exists?(output_path)
    end
  end

  describe "manifests/0" do
    test "returns the manifest target dir so `mix clean` removes it", %{target: target} do
      assert ArborTs.manifests() == [target]
    end
  end

  describe "clean/0" do
    test "deletes the manifest target dir", %{target: target} do
      Manifest.stamp(TypespecProbe, "lib/x.ex", target)
      assert File.dir?(Path.join(target, inspect(TypespecProbe)))

      ArborTs.clean()

      refute File.exists?(target)
    end
  end
end
