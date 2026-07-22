defmodule Cake.CredoChecks.CaseOnBoolean do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      Using `case` to branch on a boolean is better written as `if`/`unless`.

      A `case` whose every clause matches a boolean literal is just an `if` in
      disguise — `if`/`unless` states the intent more directly.

          # not preferred
          case active? do
            true -> :on
            false -> :off
          end

          # preferred
          if active?, do: :on, else: :off

      `cond` is unaffected — its `true ->` catch-all is not a boolean subject.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # A `case` expression: {:case, meta, [subject, [do: clauses]]}.
  defp traverse({:case, meta, [_subject, [do: clauses]]} = ast, issues, issue_meta)
       when is_list(clauses) do
    if all_boolean_clauses?(clauses) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # True when the case has clauses and every clause head is a bare `true`/`false`
  # literal (ignoring guards, which never apply to boolean literals anyway).
  defp all_boolean_clauses?(clauses) do
    heads = Enum.map(clauses, &clause_head/1)
    heads != [] and Enum.all?(heads, &(&1 in [true, false]))
  end

  defp clause_head({:->, _meta, [[head | _guards], _body]}), do: head
  defp clause_head(_), do: :not_a_boolean

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "Prefer `if`/`unless` over `case` on a boolean value.",
      line_no: line_no
    )
  end
end
