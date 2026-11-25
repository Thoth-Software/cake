defmodule CakeWeb.CoreComponentsTest do
  @moduledoc """
  The components Cake adds to the generated library, and the one it extends:
  the three state components every screen shares (#392), `empty_state/1`,
  `working/1` and `notice/1`; the status badge (#380), `status_badge/1`; and
  a column's `class` on the generated `table/1` (#380).

  Each is rendered on its own, with no request and no database. Every value
  of an attribute is enumerated, so nothing is left for a property to sample.
  The styling itself is not checked here: the suite cannot see a style
  (`.claude/rules/front-end.md`). What is checked is the structure a screen
  and its tests rely on: the `id`, the role, the text, and which daisyUI
  variant the kind selects. An icon and a daisyUI variant are each named by
  a class, so those two are pinned by class; everything else is selected by
  `id` or `data-part`.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CakeWeb.CoreComponents

  defp parse(rendered) do
    rendered |> rendered_to_string() |> Floki.parse_fragment!()
  end

  defp text(html), do: html |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp classes(node) do
    node |> Floki.attribute("class") |> Enum.flat_map(&String.split/1)
  end

  describe "empty_state/1" do
    test "shows its sentence under an icon, in an element with the given id" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.empty_state id="no-documents">
          Nothing has been uploaded yet.
        </CoreComponents.empty_state>
        """)

      assert [root] = Floki.find(html, "#no-documents")
      assert text(root) == "Nothing has been uploaded yet."
      assert [_icon] = Floki.find(root, ~s|span[class*="hero-"]|)
    end

    test "uses the icon it is given" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.empty_state id="empty" icon="hero-magnifying-glass">
          No matches.
        </CoreComponents.empty_state>
        """)

      assert [icon] = Floki.find(html, ~s|#empty span[class*="hero-"]|)
      assert "hero-magnifying-glass" in classes(icon)
    end

    test "shows the action when one is given" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.empty_state id="empty">
          Nothing has been uploaded yet.
          <:action><a href="/upload">Upload a document</a></:action>
        </CoreComponents.empty_state>
        """)

      assert [link] = Floki.find(html, "#empty a")
      assert Floki.attribute(link, "href") == ["/upload"]
      assert text(link) == "Upload a document"
    end

    test "has no action area when none is given" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.empty_state id="empty">Nothing here.</CoreComponents.empty_state>
        """)

      assert Floki.find(html, "#empty a") == []
      assert Floki.find(html, ~s|#empty [data-part="action"]|) == []
    end
  end

  describe "working/1" do
    test "announces its text as a status, beside an indicator hidden from screen readers" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.working id="ingesting">Ingesting documents...</CoreComponents.working>
        """)

      assert [root] = Floki.find(html, "#ingesting")
      assert Floki.attribute(root, "role") == ["status"]
      assert text(root) == "Ingesting documents..."

      assert [indicator] = Floki.find(root, ~s|[data-part="indicator"]|)
      assert Floki.attribute(indicator, "aria-hidden") == ["true"]
    end
  end

  describe "notice/1" do
    # An error or a warning interrupts a screen reader; information and
    # success wait their turn.
    @roles %{info: "status", success: "status", warning: "alert", error: "alert"}

    for {kind, role} <- @roles do
      test "kind #{kind}: a daisyUI #{kind} alert, announced as #{role}, with an icon" do
        assigns = %{kind: unquote(kind)}

        html =
          parse(~H"""
          <CoreComponents.notice id="notice" kind={@kind}>Something to know.</CoreComponents.notice>
          """)

        assert [root] = Floki.find(html, "#notice")
        assert "alert" in classes(root)
        assert "alert-#{unquote(kind)}" in classes(root)
        assert Floki.attribute(root, "role") == [unquote(role)]
        assert text(root) == "Something to know."
        assert [_icon] = Floki.find(root, ~s|span[class*="hero-"]|)
      end
    end

    # A notice that arrives together with what it is about (the chat's
    # warning under an answer) must not be spoken ahead of it.
    for kind <- [:info, :success, :warning, :error], role <- ["note", "status", "alert"] do
      test "kind #{kind} with role #{role}: the role given replaces the kind's, and nothing else changes" do
        assigns = %{kind: unquote(kind), role: unquote(role)}

        html =
          parse(~H"""
          <CoreComponents.notice id="notice" kind={@kind} role={@role}>
            Something to know.
          </CoreComponents.notice>
          """)

        assert [root] = Floki.find(html, "#notice")
        assert Floki.attribute(root, "role") == [unquote(role)]
        assert "alert-#{unquote(kind)}" in classes(root)
        assert [_icon] = Floki.find(root, ~s|span[class*="hero-"]|)
      end
    end

    test "is an info notice unless told otherwise" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.notice id="notice">Something to know.</CoreComponents.notice>
        """)

      assert [root] = Floki.find(html, "#notice")
      assert "alert-info" in classes(root)
    end

    test "shows its title above the body when given one" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.notice id="notice" kind={:warning} title="These archives were not ingested">
          big.zip: too many entries
        </CoreComponents.notice>
        """)

      assert [title] = Floki.find(html, ~s|#notice [data-part="title"]|)
      assert text(title) == "These archives were not ingested"
      assert [body] = Floki.find(html, ~s|#notice [data-part="body"]|)
      assert text(body) == "big.zip: too many entries"
    end

    test "has no title element when given none" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.notice id="notice">Something to know.</CoreComponents.notice>
        """)

      assert Floki.find(html, ~s|#notice [data-part="title"]|) == []
    end
  end

  # An ingestion status, shown the same way wherever one is shown: the
  # documents list and a document's page today (#380).
  describe "status_badge/1" do
    # The colours are the ones `.claude/rules/front-end.md` gives a status:
    # done, under way, failed, not started.
    test "names each status and gives it the status's own colour" do
      expected = [
        pending: {"Pending", "badge-ghost"},
        processing: {"Processing", "badge-warning"},
        completed: {"Completed", "badge-success"},
        failed: {"Failed", "badge-error"}
      ]

      for {status, {label, variant}} <- expected do
        assigns = %{status: status}

        html = parse(~H"<CoreComponents.status_badge status={@status} />")

        assert [badge] = Floki.find(html, ~s|[data-part="status"]|)
        assert text(badge) == label
        assert "badge" in classes(badge)
        assert "badge-soft" in classes(badge)
        assert variant in classes(badge)

        other_variants =
          for {_, {_, other}} <- expected, other != variant, do: other

        assert Enum.all?(other_variants, &(&1 not in classes(badge)))
      end
    end

    test "carries the id it is given, and none when given none" do
      assigns = %{}

      html =
        parse(~H"""
        <CoreComponents.status_badge id="book-status" status={:completed} />
        <CoreComponents.status_badge status={:failed} />
        """)

      assert [with_id, without_id] = Floki.find(html, ~s|[data-part="status"]|)
      assert Floki.attribute(with_id, "id") == ["book-status"]
      assert Floki.attribute(without_id, "id") == []
    end
  end

  # The generated `table/1` gives a column a label and nothing else. A table
  # of five columns does not fit a phone, so a column can carry a class that
  # hides it there: the class has to be on the column's heading and on each
  # of its cells, or the heading stays behind.
  describe "table/1, a column's class" do
    test "is on the column's heading and on each of its cells, and on no other column's" do
      assigns = %{rows: [%{id: "a", name: "Ada", pages: 3}, %{id: "b", name: "Bob", pages: 5}]}

      html =
        parse(~H"""
        <CoreComponents.table id="people" rows={@rows} row_id={&"people-#{&1.id}"}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:col :let={row} label="Pages" class="hidden sm:table-cell">{row.pages}</:col>
        </CoreComponents.table>
        """)

      assert [name_heading, pages_heading] = Floki.find(html, "thead th")
      assert "hidden" not in classes(name_heading)
      assert ["hidden", "sm:table-cell"] -- classes(pages_heading) == []

      for row <- ["#people-a", "#people-b"] do
        assert [name_cell, pages_cell] = Floki.find(html, "#{row} td")
        assert "hidden" not in classes(name_cell)
        assert ["hidden", "sm:table-cell"] -- classes(pages_cell) == []
      end
    end
  end
end
