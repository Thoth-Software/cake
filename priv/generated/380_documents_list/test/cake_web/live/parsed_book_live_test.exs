defmodule CakeWeb.ParsedBookLiveTest do
  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Cake.BooksFixtures

  @create_attrs %{title: "some title", total_pages: 42, word_count: 42, authors: ["option1", "option2"], embedding_status: :pending}
  @update_attrs %{title: "some updated title", total_pages: 43, word_count: 43, authors: ["option1"], embedding_status: :processing}
  @invalid_attrs %{title: nil, total_pages: nil, word_count: nil, authors: [], embedding_status: nil}
  defp create_parsed_book(_) do
    parsed_book = parsed_book_fixture()

    %{parsed_book: parsed_book}
  end

  describe "Index" do
    setup [:create_parsed_book]

    test "lists all parsed_books", %{conn: conn, parsed_book: parsed_book} do
      {:ok, _index_live, html} = live(conn, ~p"/parsed_books")

      assert html =~ "Listing Parsed books"
      assert html =~ parsed_book.title
    end

    test "saves new parsed_book", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/parsed_books")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Parsed book")
               |> render_click()
               |> follow_redirect(conn, ~p"/parsed_books/new")

      assert render(form_live) =~ "New Parsed book"

      assert form_live
             |> form("#parsed_book-form", parsed_book: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#parsed_book-form", parsed_book: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/parsed_books")

      html = render(index_live)
      assert html =~ "Parsed book created successfully"
      assert html =~ "some title"
    end

    test "updates parsed_book in listing", %{conn: conn, parsed_book: parsed_book} do
      {:ok, index_live, _html} = live(conn, ~p"/parsed_books")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#parsed_books-#{parsed_book.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/parsed_books/#{parsed_book}/edit")

      assert render(form_live) =~ "Edit Parsed book"

      assert form_live
             |> form("#parsed_book-form", parsed_book: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#parsed_book-form", parsed_book: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/parsed_books")

      html = render(index_live)
      assert html =~ "Parsed book updated successfully"
      assert html =~ "some updated title"
    end

    test "deletes parsed_book in listing", %{conn: conn, parsed_book: parsed_book} do
      {:ok, index_live, _html} = live(conn, ~p"/parsed_books")

      assert index_live |> element("#parsed_books-#{parsed_book.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#parsed_books-#{parsed_book.id}")
    end
  end

  describe "Show" do
    setup [:create_parsed_book]

    test "displays parsed_book", %{conn: conn, parsed_book: parsed_book} do
      {:ok, _show_live, html} = live(conn, ~p"/parsed_books/#{parsed_book}")

      assert html =~ "Show Parsed book"
      assert html =~ parsed_book.title
    end

    test "updates parsed_book and returns to show", %{conn: conn, parsed_book: parsed_book} do
      {:ok, show_live, _html} = live(conn, ~p"/parsed_books/#{parsed_book}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/parsed_books/#{parsed_book}/edit?return_to=show")

      assert render(form_live) =~ "Edit Parsed book"

      assert form_live
             |> form("#parsed_book-form", parsed_book: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#parsed_book-form", parsed_book: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/parsed_books/#{parsed_book}")

      html = render(show_live)
      assert html =~ "Parsed book updated successfully"
      assert html =~ "some updated title"
    end
  end
end
