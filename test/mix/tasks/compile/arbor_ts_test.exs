defmodule Mix.Tasks.Compile.ArborTsTest do
  use ExUnit.Case, async: true

  alias Arbor.Codegen.TypeScript
  alias Arbor.TestSupport.TypespecProbe
  alias Mix.Tasks.Compile.ArborTs

  setup do
    tmp = Path.join(System.tmp_dir!(), "arbor_ts_compiler_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, output: Path.join(tmp, "arbor.ts")}
  end

  describe "do_run/3 with no eligible modules" do
    test "returns :noop without writing the bundle file when none exists", %{output: output} do
      assert ArborTs.do_run([], [], output) == :noop
      refute File.exists?(output)
    end

    test "returns :noop in --check mode when no bundle file exists", %{output: output} do
      assert ArborTs.do_run(["--check"], [], output) == :noop
      refute File.exists?(output)
    end

    test "rewrites a stale bundle when one exists on disk", %{output: output} do
      File.write!(output, "// stale content from prior generation\n")
      assert {:ok, []} = ArborTs.do_run([], [], output)
      assert File.read!(output) == TypeScript.render([])
    end

    test "returns drift diagnostic in --check mode when a stale bundle exists", %{output: output} do
      File.write!(output, "// stale content from prior generation\n")

      assert {:error, [diagnostic]} = ArborTs.do_run(["--check"], [], output)
      assert diagnostic.severity == :error
      assert diagnostic.compiler_name == "arbor_ts"
      assert File.read!(output) == "// stale content from prior generation\n"
    end
  end

  describe "do_run/3 with eligible modules" do
    test "writes the bundle when the file is missing", %{output: output} do
      assert {:ok, []} = ArborTs.do_run([], [TypespecProbe], output)
      assert File.exists?(output)
      assert File.read!(output) == TypeScript.render([TypespecProbe])
    end

    test "returns :noop when on-disk contents match", %{output: output} do
      File.write!(output, TypeScript.render([TypespecProbe]))
      assert ArborTs.do_run([], [TypespecProbe], output) == :noop
    end

    test "rewrites the bundle on drift", %{output: output} do
      File.write!(output, "// stale\n")
      assert {:ok, []} = ArborTs.do_run([], [TypespecProbe], output)
      assert File.read!(output) == TypeScript.render([TypespecProbe])
    end
  end

  describe "do_run/3 --check" do
    test "returns :noop when bundle on disk matches the renderer", %{output: output} do
      File.write!(output, TypeScript.render([TypespecProbe]))
      assert ArborTs.do_run(["--check"], [TypespecProbe], output) == :noop
    end

    test "returns an error diagnostic on drift and does not touch the file", %{output: output} do
      File.write!(output, "// stale\n")

      assert {:error, [diagnostic]} = ArborTs.do_run(["--check"], [TypespecProbe], output)
      assert diagnostic.compiler_name == "arbor_ts"
      assert diagnostic.severity == :error
      assert diagnostic.file == output
      assert diagnostic.message =~ "out of date"
      assert File.read!(output) == "// stale\n"
    end

    test "returns an error diagnostic when the file is missing", %{output: output} do
      assert {:error, [diagnostic]} = ArborTs.do_run(["--check"], [TypespecProbe], output)
      assert diagnostic.severity == :error
      refute File.exists?(output)
    end
  end

  describe "manifests/0" do
    test "returns one manifest path under the project's manifest dir" do
      assert [path] = ArborTs.manifests()
      assert String.ends_with?(path, "compile.arbor_ts")
    end
  end
end
