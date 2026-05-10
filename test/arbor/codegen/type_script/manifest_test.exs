defmodule Arbor.Codegen.TypeScript.ManifestTest do
  use ExUnit.Case, async: true

  alias Arbor.Codegen.TypeScript.Manifest
  alias Arbor.TestSupport.TypespecProbe
  alias Arbor.TestSupport.TypespecProbeChild

  setup do
    target =
      Path.join(System.tmp_dir!(), "arbor_ts_manifest_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf!(target) end)
    {:ok, target: target}
  end

  describe "stamp/3" do
    test "writes a state.term file capturing fields and commands", %{target: target} do
      Manifest.stamp(TypespecProbe, "lib/some_consumer/typespec_probe.ex", target)

      state_path = Path.join([target, inspect(TypespecProbe), "state.term"])
      assert File.exists?(state_path)

      data =
        state_path
        |> File.read!()
        |> :erlang.binary_to_term()

      assert data.module == TypespecProbe
      assert is_list(data.fields) and data.fields != []
      assert is_list(data.commands)
    end

    test "stamping the same module twice is idempotent", %{target: target} do
      Manifest.stamp(TypespecProbe, "lib/x.ex", target)
      first = File.read!(Path.join([target, inspect(TypespecProbe), "state.term"]))

      Manifest.stamp(TypespecProbe, "lib/x.ex", target)
      second = File.read!(Path.join([target, inspect(TypespecProbe), "state.term"]))

      assert first == second
    end
  end

  describe "list/1" do
    test "returns sorted {module, %{fields, commands}} entries", %{target: target} do
      Manifest.stamp(TypespecProbeChild, "lib/x.ex", target)
      Manifest.stamp(TypespecProbe, "lib/y.ex", target)

      assert [{first_mod, first_data}, {second_mod, _second_data}] = Manifest.list(target)

      # Sorted by Module.split — TypespecProbe < TypespecProbeChild
      assert first_mod == TypespecProbe
      assert second_mod == TypespecProbeChild
      assert is_list(first_data.fields)
      assert is_list(first_data.commands)
    end

    test "returns [] for missing target dir", %{target: target} do
      File.rm_rf!(target)
      assert Manifest.list(target) == []
    end

    test "skips orphan dirs whose state.term is corrupt", %{target: target} do
      Manifest.stamp(TypespecProbe, "lib/x.ex", target)

      # Write a junk dir alongside a valid one
      junk_dir = Path.join(target, "Some.Garbage.Module")
      File.mkdir_p!(junk_dir)
      File.write!(Path.join(junk_dir, "state.term"), "not a binary term")

      entries = Manifest.list(target)
      assert [{TypespecProbe, _data}] = entries
    end
  end

  describe "clean_outdated/1" do
    test "removes dirs whose module no longer loads", %{target: target} do
      # Create an orphan dir for a non-existent module
      orphan = Path.join(target, "Definitely.Not.A.Real.Module")
      File.mkdir_p!(orphan)

      File.write!(
        Path.join(orphan, "state.term"),
        :erlang.term_to_binary(%{module: :__not_a_real_module__, fields: [], commands: []})
      )

      Manifest.stamp(TypespecProbe, "lib/x.ex", target)

      Manifest.clean_outdated(target)

      refute File.exists?(orphan)
      assert File.dir?(Path.join(target, inspect(TypespecProbe)))
    end

    test "is a no-op when target dir is missing", %{target: target} do
      File.rm_rf!(target)
      assert Manifest.clean_outdated(target) == :ok
    end
  end

  describe "__after_compile__/2" do
    test "stamps modules whose source lives outside test/", %{target: target} do
      Process.put(:__arbor_ts_target_dir__, target)

      env = %{module: TypespecProbe, file: "/abs/lib/whatever/typespec_probe.ex"}

      Manifest.__after_compile__(env, "")

      state_path = Path.join([target, inspect(TypespecProbe), "state.term"])
      assert File.exists?(state_path)
    end

    test "skips modules whose source lives under test/", %{target: target} do
      Process.put(:__arbor_ts_target_dir__, target)

      env = %{module: TypespecProbe, file: "/abs/test/support/typespec_probe.ex"}

      Manifest.__after_compile__(env, "")

      refute File.exists?(Path.join([target, inspect(TypespecProbe), "state.term"]))
    end

    test "skips modules whose source lives in a top-level test/ file", %{target: target} do
      Process.put(:__arbor_ts_target_dir__, target)

      env = %{module: TypespecProbe, file: "/abs/test/something_test.exs"}

      Manifest.__after_compile__(env, "")

      refute File.exists?(Path.join([target, inspect(TypespecProbe), "state.term"]))
    end
  end
end
