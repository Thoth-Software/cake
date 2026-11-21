defmodule Cake.BooksPropertyTest do
  @moduledoc """
  Properties of the two queries the documents list reads through (#380):
  `Cake.Books.list_parsed_books_newest_first/0` and `Cake.Books.count_chunks/1`.

  A property's iterations share one sandbox transaction, so the books of
  earlier iterations are still there in later ones. Both properties are
  stated so that this does not matter: the list is checked against every
  book in the table, and a count against the chunks of the book in hand.

  Example tests are in `test/cake/books_test.exs`.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  import Cake.BooksFixtures

  alias Cake.Books
  alias Cake.Repo

  # Each iteration inserts books and chunks.
  @max_runs 25

  # An upload time to the second, as the column stores it. Drawn from a
  # narrow range so that two books often share one: `inserted_at` has a
  # resolution of a second, and a batch upload lands within one.
  defp uploaded_at do
    map(integer(0..5), &DateTime.add(~U[2026-01-01 00:00:00Z], &1, :second))
  end

  defp book_uploaded_at(uploaded_at) do
    parsed_book_fixture()
    |> Ecto.Changeset.change(inserted_at: uploaded_at)
    |> Repo.update!()
  end

  describe "list_parsed_books_newest_first/0" do
    property "is every book, by upload time descending and then by id" do
      check all(times <- list_of(uploaded_at(), max_length: 6), max_runs: @max_runs) do
        Enum.each(times, &book_uploaded_at/1)

        expected =
          Books.list_parsed_books()
          |> Enum.sort_by(& &1.id)
          |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

        assert Enum.map(Books.list_parsed_books_newest_first(), & &1.id) ==
                 Enum.map(expected, & &1.id)
      end
    end
  end

  describe "count_chunks/1" do
    property "is the number of chunks the book has, whatever other books have" do
      check all(
              count <- integer(0..6),
              others <- integer(0..3),
              max_runs: @max_runs
            ) do
        {book, _chunks} = book_with_chunks_fixture(List.duplicate(%{}, count))
        {_other, _chunks} = book_with_chunks_fixture(List.duplicate(%{}, others))

        assert Books.count_chunks(book) == count
      end
    end
  end
end
