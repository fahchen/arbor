defmodule Arbor.CredoChecks.DoubleReverse do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :refactor,
    explanations: [
      check: """
      Detects the `Enum.reverse([head | Enum.reverse(tail)])` pattern, which
      reverses the list twice just to append `head` at the end. Use
      `List.insert_at(tail, -1, head)` instead — same result, single traversal,
      reads more directly.

      Example:

          # bad
          Enum.reverse([id | Enum.reverse(parent_path)])

          # good
          List.insert_at(parent_path, -1, id)
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  # Match `Enum.reverse([_head | Enum.reverse(_tail)])`.
  defp walk(
         {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, meta,
          [
            [
              {:|, _,
               [
                 _head,
                 {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, [_tail]}
               ]}
            ]
          ]} = ast,
         ctx
       ) do
    {ast, put_issue(ctx, issue_for(ctx, meta))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "Avoid `Enum.reverse([head | Enum.reverse(tail)])`; use `List.insert_at(tail, -1, head)` for tail-append.",
      trigger: "Enum.reverse",
      line_no: meta[:line]
    )
  end
end
