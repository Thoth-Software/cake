defmodule Cake.CredoChecks.RawInHeex do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid `raw/1` inside HEEx templates.

      HEEx auto-escapes interpolated values; `raw/1` (and `Phoenix.HTML.raw/1`)
      opts out of that escaping and reintroduces XSS risk. Prefer rendering
      structured content through components and assigns so it stays escaped.

          # not preferred
          ~H"<article>{raw(@user_supplied_html)}</article>"

      This check scans `~H` sigil bodies. HEEx interpolations are not exposed as
      Elixir AST — the sigil body is a string literal at the AST level — so the
      body is inspected as text. (Standalone `.heex` files are not parsed by
      Credo and are out of scope.)
      """
    ]

  @raw_call ~r/(?<!\w)raw\s*\(/

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # ~H sigil: {:sigil_H, meta, [{:<<>>, _, parts}, _modifiers]}. The parts are
  # binary segments; ~H disables #{} interpolation, so the body is plain text.
  defp traverse({:sigil_H, meta, [{:<<>>, _, parts}, _mods]} = ast, issues, issue_meta) do
    text = parts |> Enum.filter(&is_binary/1) |> Enum.join()

    if Regex.match?(@raw_call, text) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "Avoid `raw/1` in HEEx templates — it disables HTML escaping (XSS risk).",
      line_no: line_no
    )
  end
end
