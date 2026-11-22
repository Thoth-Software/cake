defmodule CakeWeb.ParsedBookLiveTest do
  @moduledoc """
  The documents list at `/documents` and one document at `/documents/:id`
  (#380): a read-only view of what has been uploaded.

  The modules keep the names `mix phx.gen.live` gave them
  (`CakeWeb.ParsedBookLive.Index` and `.Show`); to a user the screen is
  "Documents".

  The pages show what the database says. A book whose status is stale
  (#305), a scanned PDF marked completed with nothing searchable (#293) and
  a title the parser got wrong (#86) are shown as stored: nothing here pins
  a correction of them.
  """

  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Cake.BooksFixtures

  alias Cake.Books.Adapters

  # A book as the fixture makes it, then dated: `inserted_at` is set by the
  # database layer, not cast from attrs.
  defp book_uploaded_at(attrs, %DateTime{} = uploaded_at) do
    attrs
    |> parsed_book_fixture()
    |> Ecto.Changeset.change(inserted_at: uploaded_at)
    |> Cake.Repo.update!()
  end

  defp parse(html), do: Floki.parse_document!(html)

  defp text(html, selector) do
    html |> Floki.find(selector) |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp classes(html, selector) do
    html |> Floki.find(selector) |> Floki.attribute("class") |> Enum.flat_map(&String.split/1)
  end

  # The ids of the list's rows, in page order.
  defp row_ids(html),
    do: html |> parse() |> Floki.find("#documents > tr") |> Floki.attribute("id")

  defp row(book), do: "#documents-#{book.id}"

  defp download_path(key), do: ~p"/books/download/#{String.split(key, "/")}"

  describe "access" do
    test "an anonymous visitor is sent to the log-in page from the list", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/documents")
      assert path == ~p"/users/log_in"
    end

    test "an anonymous visitor is sent to the log-in page from a document", %{conn: conn} do
      book = parsed_book_fixture()

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/documents/#{book}")
      assert path == ~p"/users/log_in"
    end

    test "the same holds for a plain request, before any LiveView is mounted", %{conn: conn} do
      book = parsed_book_fixture()

      assert conn |> get(~p"/documents") |> redirected_to() == ~p"/users/log_in"
      assert conn |> get(~p"/documents/#{book}") |> redirected_to() == ~p"/users/log_in"
    end
  end

  describe "the list" do
    setup :register_and_log_in_user

    test "is headed Documents and asks for the wide column", %{conn: conn} do
      parsed_book_fixture()
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert html |> parse() |> text("#page h1") == "Documents"
      assert html |> parse() |> Floki.attribute("#page", "data-width") == ["wide"]
    end

    test "shows every document, newest first", %{conn: conn} do
      oldest = book_uploaded_at(%{title: "Oldest"}, ~U[2026-01-01 09:00:00Z])
      newest = book_uploaded_at(%{title: "Newest"}, ~U[2026-03-01 09:00:00Z])
      middle = book_uploaded_at(%{title: "Middle"}, ~U[2026-02-01 09:00:00Z])

      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert row_ids(html) == Enum.map([newest, middle, oldest], &"documents-#{&1.id}")
    end

    test "shows a document's title as a link to its page", %{conn: conn} do
      book = parsed_book_fixture(%{title: "Annual Report"})
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert [title] = html |> parse() |> Floki.find(~s|#{row(book)} a[data-part="title"]|)
      assert title |> Floki.text() |> String.trim() == "Annual Report"
      assert Floki.attribute(title, "href") == [~p"/documents/#{book}"]
    end

    # As the chat displays a title: without control and replacement
    # characters, without Word's "Microsoft Word - " prefix, trimmed. Nothing
    # more is corrected here (#86).
    test "displays a title as the chat does", %{conn: conn} do
      book = parsed_book_fixture(%{title: "Microsoft Word - Quarterly\u0001 Plan�.docx  "})
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert html |> parse() |> text(~s|#{row(book)} [data-part="title"]|) ==
               "Quarterly Plan.docx"
    end

    # The chat spells out the page of a citation label. A stored title that
    # happens to mention a page is not one.
    test "leaves a title that mentions a page as it is", %{conn: conn} do
      book = parsed_book_fixture(%{title: "Style Guide, p. 2 errata"})
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert html |> parse() |> text(~s|#{row(book)} [data-part="title"]|) ==
               "Style Guide, p. 2 errata"

      assert conn
             |> get(~p"/documents/#{book}")
             |> html_response(200)
             |> parse()
             |> text("#page h1") ==
               "Style Guide, p. 2 errata"
    end

    test "calls a document Untitled when nothing of its title can be shown, and still links to it",
         %{conn: conn} do
      book = parsed_book_fixture(%{title: "\uFFFD\u0001"})
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert [title] = html |> parse() |> Floki.find(~s|#{row(book)} a[data-part="title"]|)
      assert title |> Floki.text() |> String.trim() == "Untitled"
      assert Floki.attribute(title, "href") == [~p"/documents/#{book}"]
    end

    test "shows the page count, and a dash for a document that has none", %{conn: conn} do
      counted = parsed_book_fixture(%{total_pages: 317})
      uncounted = parsed_book_fixture(%{total_pages: nil})
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert html |> parse() |> text(~s|#{row(counted)} [data-part="pages"]|) == "317"
      assert html |> parse() |> text(~s|#{row(uncounted)} [data-part="pages"]|) == "—"
    end

    # The colours are the ones every screen uses for a status
    # (`.claude/rules/front-end.md`, "Chips and badges"). The variant is
    # named by a class, so the class is what is pinned.
    test "shows each status as a badge, in the status's own colour", %{conn: conn} do
      expected = [
        pending: {"Pending", "badge-ghost"},
        processing: {"Processing", "badge-warning"},
        completed: {"Completed", "badge-success"},
        failed: {"Failed", "badge-error"}
      ]

      books = for {status, _} <- expected, do: parsed_book_fixture(%{embedding_status: status})
      {:ok, _lv, html} = live(conn, ~p"/documents")
      doc = parse(html)

      for {book, {_status, {label, variant}}} <- Enum.zip(books, expected) do
        badge = ~s|#{row(book)} [data-part="status"]|

        assert text(doc, badge) == label
        assert "badge" in classes(doc, badge)
        assert variant in classes(doc, badge)
      end
    end

    test "shows when a document was uploaded, in UTC, readable by a machine too", %{conn: conn} do
      book = book_uploaded_at(%{}, ~U[2026-11-20 14:05:09Z])
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert [uploaded] =
               html |> parse() |> Floki.find(~s|#{row(book)} time[data-part="uploaded"]|)

      assert Floki.attribute(uploaded, "datetime") == ["2026-11-20T14:05:09Z"]
      assert uploaded |> Floki.text() |> String.trim() == "2026-11-20 14:05 UTC"
    end

    test "links to the source through the download route, one path segment per key segment",
         %{conn: conn} do
      key = Adapters.build_key("books", "report_#{System.unique_integer([:positive])}")
      book = parsed_book_fixture(%{source_file_path: key})
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert html |> parse() |> Floki.attribute(~s|#{row(book)} a[data-part="source"]|, "href") ==
               [download_path(key)]
    end

    # Every row has a download link; a screen reader lists links out of their
    # rows, so each one's name says which document it fetches.
    test "names each download link after its document", %{conn: conn} do
      report = parsed_book_fixture(%{title: "Annual Report"})
      notes = parsed_book_fixture(%{title: "Microsoft Word - Field Notes"})
      {:ok, _lv, html} = live(conn, ~p"/documents")
      doc = parse(html)

      assert Floki.attribute(doc, ~s|#{row(report)} a[data-part="source"]|, "aria-label") ==
               ["Download Annual Report"]

      assert Floki.attribute(doc, ~s|#{row(notes)} a[data-part="source"]|, "aria-label") ==
               ["Download Field Notes"]
    end

    test "offers nothing that creates, edits or deletes", %{conn: conn} do
      book = parsed_book_fixture()
      {:ok, lv, html} = live(conn, ~p"/documents")
      page = html |> parse() |> Floki.find("#page")

      assert Floki.find(page, "form") == []
      assert Floki.find(page, "[data-confirm]") == []
      assert Floki.find(page, ~s|a[href$="/new"]|) == []
      assert Floki.find(page, ~s|a[href$="/edit"]|) == []
      refute has_element?(lv, "#{row(book)} a", "Edit")
      refute has_element?(lv, "#{row(book)} a", "Delete")
    end
  end

  describe "the list, with nothing uploaded" do
    setup :register_and_log_in_user

    test "says so in a sentence and links to Upload, with no table", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/documents")
      doc = parse(html)

      assert [_] = Floki.find(doc, "#documents-empty")

      assert Floki.attribute(doc, ~s|#documents-empty [data-part="action"] a|, "href") == [
               ~p"/upload"
             ]

      assert Floki.find(doc, "#page table") == []
    end

    test "a list with a document in it has no empty state", %{conn: conn} do
      parsed_book_fixture()
      {:ok, _lv, html} = live(conn, ~p"/documents")

      assert html |> parse() |> Floki.find("#documents-empty") == []
    end
  end

  # The list is read when the page opens, and nothing announces that an
  # ingest finished: the page offers a refresh instead.
  describe "the list's refresh button" do
    setup :register_and_log_in_user

    test "shows a document uploaded since the page was opened, above the older ones",
         %{conn: conn} do
      older = book_uploaded_at(%{}, ~U[2026-01-01 09:00:00Z])
      {:ok, lv, html} = live(conn, ~p"/documents")
      assert row_ids(html) == ["documents-#{older.id}"]

      newer = book_uploaded_at(%{}, ~U[2026-02-01 09:00:00Z])
      refute has_element?(lv, row(newer))

      refreshed = lv |> element("#documents-refresh") |> render_click()

      assert row_ids(refreshed) == ["documents-#{newer.id}", "documents-#{older.id}"]
    end

    # A refresh that finds nothing new changes no row, so the page says when
    # the list was last read: that is what shows the button did something.
    # The time is shown to the second and carried to the microsecond, so two
    # reads within one second are still told apart here.
    test "says when the list was read, and reads it again", %{conn: conn} do
      parsed_book_fixture()
      opened_at = DateTime.utc_now()
      {:ok, lv, html} = live(conn, ~p"/documents")

      read_at = fn html ->
        assert [time] = html |> parse() |> Floki.find("time#documents-read-at")
        assert [iso] = Floki.attribute(time, "datetime")
        assert {:ok, at, 0} = DateTime.from_iso8601(iso)
        assert time |> Floki.text() |> String.trim() == Calendar.strftime(at, "%H:%M:%S UTC")
        at
      end

      first = read_at.(html)
      assert DateTime.compare(first, opened_at) != :lt

      second = lv |> element("#documents-refresh") |> render_click() |> read_at.()
      assert DateTime.compare(second, first) == :gt
    end

    test "shows a status that has changed since", %{conn: conn} do
      book = parsed_book_fixture(%{embedding_status: :processing})
      {:ok, lv, _html} = live(conn, ~p"/documents")

      {:ok, _} = Cake.Books.update_parsed_book(book, %{embedding_status: :completed})
      html = lv |> element("#documents-refresh") |> render_click()

      assert html |> parse() |> text(~s|#{row(book)} [data-part="status"]|) == "Completed"
    end

    test "replaces the empty state with the list once something has been uploaded",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/documents")
      assert has_element?(lv, "#documents-empty")

      book = parsed_book_fixture()
      lv |> element("#documents-refresh") |> render_click()

      refute has_element?(lv, "#documents-empty")
      assert has_element?(lv, row(book))
    end
  end

  describe "one document" do
    setup :register_and_log_in_user

    test "is headed with its title, displayed as the list displays it", %{conn: conn} do
      book = parsed_book_fixture(%{title: "Microsoft Word - Field Notes"})
      {:ok, _lv, html} = live(conn, ~p"/documents/#{book}")

      assert html |> parse() |> text("#page h1") == "Field Notes"
    end

    test "is titled with the document's title and then the product's", %{conn: conn} do
      book = parsed_book_fixture(%{title: "Field Notes"})

      assert conn |> get(~p"/documents/#{book}") |> html_response(200) |> parse() |> text("title") ==
               "Field Notes · Cake"
    end

    test "shows the list's fields, and the authors, the word count and the number of chunks",
         %{conn: conn} do
      key = Adapters.build_key("books", "notes_#{System.unique_integer([:positive])}")

      book =
        book_uploaded_at(
          %{
            title: "Field Notes",
            authors: ["Ada Lovelace", "Grace Hopper"],
            total_pages: 317,
            word_count: 98_765,
            embedding_status: :completed,
            source_file_path: key
          },
          ~U[2026-11-20 14:05:09Z]
        )

      for index <- 0..2 do
        chunk_fixture(%{parsed_book_id: book.id, chunk_index: index})
      end

      # Another book's chunks are not this one's.
      chunk_fixture()

      {:ok, _lv, html} = live(conn, ~p"/documents/#{book}")
      doc = parse(html)

      assert text(doc, "#document-authors") == "Ada Lovelace, Grace Hopper"
      assert text(doc, "#document-pages") == "317"
      assert text(doc, "#document-word-count") == "98765"
      assert text(doc, "#document-chunk-count") == "3"
      assert text(doc, ~s|#document-status [data-part="status"]|) == "Completed"
      assert "badge-success" in classes(doc, ~s|#document-status [data-part="status"]|)

      assert Floki.attribute(doc, "#document-uploaded time", "datetime") == [
               "2026-11-20T14:05:09Z"
             ]

      assert text(doc, "#document-uploaded") == "2026-11-20 14:05 UTC"
      assert Floki.attribute(doc, "a#document-source", "href") == [download_path(key)]
    end

    test "shows a dash for what a document does not have, and zero chunks as 0", %{conn: conn} do
      book = parsed_book_fixture(%{authors: [], total_pages: nil})
      {:ok, _lv, html} = live(conn, ~p"/documents/#{book}")
      doc = parse(html)

      assert text(doc, "#document-authors") == "—"
      assert text(doc, "#document-pages") == "—"
      assert text(doc, "#document-chunk-count") == "0"
    end

    test "links back to the list, in the page and in the top bar", %{conn: conn} do
      book = parsed_book_fixture()
      {:ok, _lv, html} = live(conn, ~p"/documents/#{book}")
      doc = parse(html)

      assert Floki.attribute(doc, "a#document-back", "href") == [~p"/documents"]
      assert ~p"/documents" in Floki.attribute(doc, "#main-nav a", "href")
    end

    test "is headed Untitled when nothing of its title can be shown", %{conn: conn} do
      book = parsed_book_fixture(%{title: "\uFFFD\u0001"})

      doc = conn |> get(~p"/documents/#{book}") |> html_response(200) |> parse()

      assert text(doc, "#page h1") == "Untitled"
      assert text(doc, "title") == "Untitled · Cake"
    end

    test "offers nothing that edits or deletes", %{conn: conn} do
      book = parsed_book_fixture()
      {:ok, _lv, html} = live(conn, ~p"/documents/#{book}")
      page = html |> parse() |> Floki.find("#page")

      assert Floki.find(page, "form") == []
      assert Floki.find(page, "[data-confirm]") == []
      assert Floki.find(page, ~s|a[href*="/edit"]|) == []
    end

    test "that does not exist is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/documents/#{Ecto.UUID.generate()}") end
    end
  end
end
