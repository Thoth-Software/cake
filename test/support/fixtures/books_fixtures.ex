defmodule Cake.BooksFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Cake.Books` context.
  """

  @doc """
  Generate a unique parsed_book file_hash.
  """
  @spec unique_parsed_book_file_hash() :: String.t()
  def unique_parsed_book_file_hash, do: "some file_hash#{System.unique_integer([:positive])}"

  @doc """
  Generate a parsed_book.
  """
  @spec parsed_book_fixture(map()) :: Cake.Books.ParsedBook.t()
  def parsed_book_fixture(attrs \\ %{}) do
    {:ok, parsed_book} =
      attrs
      |> Enum.into(%{
        authors: ["option1", "option2"],
        embedding_status: :pending,
        file_hash: unique_parsed_book_file_hash(),
        file_size: 42,
        isbn: "some isbn",
        language: "some language",
        metadata: %{},
        parsed_at: ~U[2025-12-16 15:23:00Z],
        publication_date: ~D[2025-12-16],
        publisher: "some publisher",
        source_file_path: "some source_file_path",
        source_format: "some source_format",
        table_of_contents: %{},
        title: "some title",
        total_pages: 42,
        word_count: 42
      })
      |> Cake.Books.create_parsed_book()

    parsed_book
  end

  @doc """
  Generate a chunk.
  """
  @spec chunk_fixture(map()) :: Cake.Books.Chunk.t()
  def chunk_fixture(attrs \\ %{}) do
    parsed_book = parsed_book_fixture()

    {:ok, chunk} =
      attrs
      |> Enum.into(%{
        char_count: 42,
        chunk_index: 42,
        page_number: 42,
        parsed_book_id: parsed_book.id,
        section_title: "some section_title",
        text: "some text",
        word_count: 42
      })
      |> Cake.Books.create_chunk()

    chunk
  end
end
