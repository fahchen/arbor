# Run with: mix run bench/diff_bench.exs
#
# Measures `Arbor.Diff.diff/2` cost across small, large, and reorder-heavy
# wire-form trees. Reorders intentionally use no `move` op (BDR-0014) so the
# emitted op count grows with shifted positions — the bench shows the cost.

small_a = %{"title" => "before", "count" => 1, "tags" => ["a", "b"]}
small_b = %{"title" => "after", "count" => 2, "tags" => ["a", "b", "c"]}

build_large = fn variant ->
  for n <- 1..1_000, into: %{} do
    suffix = if rem(n, 7) == 0 and variant == :b, do: "+", else: ""
    {Integer.to_string(n), %{"id" => n, "name" => "row-#{n}#{suffix}"}}
  end
end

large_a = build_large.(:a)
large_b = build_large.(:b)

reorder_a = for n <- 1..200, do: %{"id" => n}
reorder_b = Enum.reverse(reorder_a)

Benchee.run(
  %{
    "diff small" => fn -> Arbor.Diff.diff(small_a, small_b) end,
    "diff large (~14% changed)" => fn -> Arbor.Diff.diff(large_a, large_b) end,
    "diff reorder (200 rev)" => fn -> Arbor.Diff.diff(reorder_a, reorder_b) end
  },
  warmup: 1,
  time: 3,
  print: [fast_warning: false]
)
