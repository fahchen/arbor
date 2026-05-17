defmodule Musubi.DiffTest do
  use ExUnit.Case, async: true

  alias Musubi.Diff

  describe "scalar and map ops" do
    test "tiny scalar change emits a single replace op" do
      assert [%{op: "replace", path: "/title", value: "Outbox"}] =
               Diff.diff(%{"title" => "Inbox"}, %{"title" => "Outbox"})
    end

    test "added key produces an add op" do
      assert [%{op: "add", path: "/age", value: 33}] =
               Diff.diff(%{"name" => "Bob"}, %{"name" => "Bob", "age" => 33})
    end

    test "removed key produces a remove op" do
      assert [%{op: "remove", path: "/age"}] =
               Diff.diff(%{"name" => "Bob", "age" => 33}, %{"name" => "Bob"})
    end

    test "no-op cycle returns []" do
      assert [] = Diff.diff(%{"a" => 1}, %{"a" => 1})
    end
  end

  describe "Scenario: Reorder of a keyed list does not use move" do
    test "list reorder produces only replace ops at affected indices" do
      ops = Diff.diff(%{"items" => [1, 2, 3]}, %{"items" => [3, 2, 1]})

      Enum.each(ops, fn op ->
        assert op.op == "replace",
               "expected only replace ops, got: #{inspect(op)}"
      end)

      refute Enum.any?(ops, &(&1.op == "move"))
    end
  end

  describe "Scenario: Bulk reorder of a 1000-element list" do
    test "diff emits per-index ops without subtree-replace fallback" do
      previous = Enum.to_list(1..1000)
      current = Enum.shuffle(previous)

      ops = Diff.diff(%{"items" => previous}, %{"items" => current})

      # No threshold; expect many ops (the spec rejects coalescing into a
      # single subtree replace).
      refute match?([%{op: "replace", path: "/items", value: _}], ops)

      Enum.each(ops, fn op ->
        assert op.op in ["add", "remove", "replace"]
        assert String.starts_with?(op.path, "/items/")
      end)
    end
  end

  describe "Scenario: Path encoding uses RFC 6901" do
    test "literal slash in field name is escaped as ~1" do
      assert [%{op: "replace", path: "/a~1b", value: 2}] =
               Diff.diff(%{"a/b" => 1}, %{"a/b" => 2})
    end

    test "literal tilde is escaped as ~0" do
      assert [%{op: "replace", path: "/x~0y", value: 2}] =
               Diff.diff(%{"x~y" => 1}, %{"x~y" => 2})
    end
  end

  describe "Rule: ops use only add, remove, replace" do
    test "diff output never contains move/copy/test ops" do
      ops =
        Diff.diff(
          %{"l" => [%{"id" => "a"}, %{"id" => "b"}]},
          %{"l" => [%{"id" => "b"}, %{"id" => "a"}]}
        )

      Enum.each(ops, fn op ->
        refute op.op in ["move", "copy", "test"]
      end)
    end
  end

  describe "Rule: function values never appear in ops" do
    test "function in current term raises ArgumentError at the diff entry" do
      assert_raise ArgumentError, ~r/Musubi\.Diff received a function value/, fn ->
        Diff.diff(%{"a" => 1}, %{"a" => fn _arg -> :nope end})
      end
    end

    test "function in previous term raises ArgumentError" do
      assert_raise ArgumentError, ~r/Musubi\.Diff received a function value/, fn ->
        Diff.diff(%{"a" => fn -> :nope end}, %{"a" => 1})
      end
    end
  end
end
