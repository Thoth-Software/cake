defmodule CakeWeb.BooksControllerTest do
  @moduledoc """
  `CakeWeb.BooksController.download/2` serves a stored book by reading its
  `ParsedBook.source_file_path` — a `Cake.Books.Adapters` storage key, as
  written by `CakeWeb.UploadLive` — through the configured adapter.

  Three branches:

    * The `file_path` segment is no `ParsedBook`'s key → 404 "Book not found".
    * A row exists but the adapter cannot read the key → 404
      "File not found in storage".
    * A row exists and the adapter returns the binary → 200 with that body,
      a Content-Type derived from the book's `source_format`, and a
      Content-Disposition attachment header naming the key's basename plus
      that format's extension.
  """

  use CakeWeb.ConnCase

  import Mox
  import Cake.BooksFixtures

  setup :verify_on_exit!
  setup :register_and_log_in_user

  defp storage_key(name) do
    Cake.Books.Adapters.build_key("books", "#{name}_#{System.unique_integer([:positive])}")
  end

  describe "authentication" do
    test "redirects to the login page when the user is not authenticated" do
      conn = get(build_conn(), ~p"/books/download/whatever.pdf")

      assert redirected_to(conn) =~ "/users/log_in"
    end
  end

  describe "GET /books/download/*file_path" do
    test "returns 404 without touching storage when no ParsedBook matches the key",
         %{conn: conn} do
      conn = get(conn, ~p"/books/download/#{storage_key("no_such_book")}")

      assert response(conn, 404) =~ "Book not found"
    end

    test "returns 404 without touching storage when the stored key could traverse the root",
         %{conn: conn} do
      # A poisoned or legacy row must never reach the adapter: the disk adapter
      # joins the key under its root, and a `..` segment would escape it.
      poisoned = "../../etc/passwd"
      _book = parsed_book_fixture(%{source_file_path: poisoned, source_format: "pdf"})

      conn = get(conn, ~p"/books/download/#{poisoned}")

      assert response(conn, 404) =~ "Book not found"
    end

    test "returns 404 when the ParsedBook row exists but the adapter cannot read the key",
         %{conn: conn} do
      key = storage_key("vanished")
      _book = parsed_book_fixture(%{source_file_path: key, source_format: "pdf"})

      expect(Cake.Books.Adapters.Mock, :read, fn ^key -> {:error, :enoent} end)

      conn = get(conn, ~p"/books/download/#{key}")

      assert response(conn, 404) =~ "File not found in storage"
    end

    test "sends the adapter's binary as a typed attachment named after the key",
         %{conn: conn} do
      key = storage_key("getting_started")
      _book = parsed_book_fixture(%{source_file_path: key, source_format: "pdf"})
      contents = "%PDF-1.7 fake test content"

      expect(Cake.Books.Adapters.Mock, :read, fn ^key -> {:ok, contents} end)

      conn = get(conn, ~p"/books/download/#{key}")

      assert response(conn, 200) == contents
      assert response_content_type(conn, :pdf)

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="#{Path.basename(key)}.pdf")]
    end

    test "keeps a key that already carries an extension as the filename", %{conn: conn} do
      key = "legacy/books/handbook.pdf"
      _book = parsed_book_fixture(%{source_file_path: key, source_format: "pdf"})

      expect(Cake.Books.Adapters.Mock, :read, fn ^key -> {:ok, "%PDF-1.7"} end)

      conn = get(conn, ~p"/books/download/#{key}")

      assert response(conn, 200) == "%PDF-1.7"

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="handbook.pdf")]
    end
  end
end
