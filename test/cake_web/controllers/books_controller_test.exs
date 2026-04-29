defmodule CakeWeb.BooksControllerTest do
  @moduledoc """
  Characterization tests for `CakeWeb.BooksController.download/2`.

  Three branches:

    * The `file_path` segment doesn't match any `ParsedBook` row → 404 with
      "Book not found".
    * A row exists but the on-disk file is gone → 404 with
      "File not found on disk".
    * Row exists and file is present → 200 with the file body and a
      Content-Disposition attachment header.
  """

  use CakeWeb.ConnCase

  import Cake.BooksFixtures

  describe "GET /books/download/*file_path" do
    test "returns 404 when no ParsedBook matches the requested path", %{conn: conn} do
      conn = get(conn, ~p"/books/download/no/such/book.pdf")

      assert response(conn, 404) =~ "Book not found"
    end

    test "returns 404 when the ParsedBook row exists but the file is missing", %{conn: conn} do
      missing_path = "/tmp/nonexistent-cake-book-#{System.unique_integer([:positive])}.pdf"
      _book = parsed_book_fixture(%{source_file_path: missing_path})

      conn = get(conn, ~p"/books/download/#{missing_path}")

      assert response(conn, 404) =~ "File not found on disk"
    end

    test "streams the file with an attachment Content-Disposition header when both exist",
         %{conn: conn} do
      tmp_path = "/tmp/cake-book-#{System.unique_integer([:positive])}.pdf"
      contents = "%PDF-1.7 fake test content"
      File.write!(tmp_path, contents)

      _book = parsed_book_fixture(%{source_file_path: tmp_path})

      conn = get(conn, ~p"/books/download/#{tmp_path}")

      assert conn.status == 200
      assert response(conn, 200) == contents

      assert {"content-disposition", disposition} =
               Enum.find(conn.resp_headers, fn {k, _} -> k == "content-disposition" end)

      assert disposition =~ ~s(filename="#{Path.basename(tmp_path)}")
    after
      tmp_files = Path.wildcard("/tmp/cake-book-*.pdf")
      Enum.each(tmp_files, &File.rm/1)
    end
  end
end
