defmodule Cake.BooksTest do
  use Cake.DataCase

  alias Cake.Books

  describe "parsed_books" do
    alias Cake.Books.ParsedBook

    import Cake.BooksFixtures

    @invalid_attrs %{title: nil, metadata: nil, language: nil, file_size: nil, source_file_path: nil, authors: nil, source_format: nil, file_hash: nil, isbn: nil, publisher: nil, publication_date: nil, total_pages: nil, word_count: nil, table_of_contents: nil, parsed_at: nil, embedding_status: nil}

    test "list_parsed_books/0 returns all parsed_books" do
      parsed_book = parsed_book_fixture()
      assert Books.list_parsed_books() == [parsed_book]
    end

    test "get_parsed_book!/1 returns the parsed_book with given id" do
      parsed_book = parsed_book_fixture()
      assert Books.get_parsed_book!(parsed_book.id) == parsed_book
    end

    test "create_parsed_book/1 with valid data creates a parsed_book" do
      valid_attrs = %{title: "some title", metadata: %{}, language: "some language", file_size: 42, source_file_path: "some source_file_path", authors: ["option1", "option2"], source_format: "some source_format", file_hash: "some file_hash", isbn: "some isbn", publisher: "some publisher", publication_date: ~D[2025-12-16], total_pages: 42, word_count: 42, table_of_contents: %{}, parsed_at: ~U[2025-12-16 15:23:00Z], embedding_status: :pending}

      assert {:ok, %ParsedBook{} = parsed_book} = Books.create_parsed_book(valid_attrs)
      assert parsed_book.title == "some title"
      assert parsed_book.metadata == %{}
      assert parsed_book.language == "some language"
      assert parsed_book.file_size == 42
      assert parsed_book.source_file_path == "some source_file_path"
      assert parsed_book.authors == ["option1", "option2"]
      assert parsed_book.source_format == "some source_format"
      assert parsed_book.file_hash == "some file_hash"
      assert parsed_book.isbn == "some isbn"
      assert parsed_book.publisher == "some publisher"
      assert parsed_book.publication_date == ~D[2025-12-16]
      assert parsed_book.total_pages == 42
      assert parsed_book.word_count == 42
      assert parsed_book.table_of_contents == %{}
      assert parsed_book.parsed_at == ~U[2025-12-16 15:23:00Z]
      assert parsed_book.embedding_status == :pending
    end

    test "create_parsed_book/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Books.create_parsed_book(@invalid_attrs)
    end

    test "update_parsed_book/2 with valid data updates the parsed_book" do
      parsed_book = parsed_book_fixture()
      update_attrs = %{title: "some updated title", metadata: %{}, language: "some updated language", file_size: 43, source_file_path: "some updated source_file_path", authors: ["option1"], source_format: "some updated source_format", file_hash: "some updated file_hash", isbn: "some updated isbn", publisher: "some updated publisher", publication_date: ~D[2025-12-17], total_pages: 43, word_count: 43, table_of_contents: %{}, parsed_at: ~U[2025-12-17 15:23:00Z], embedding_status: :completed}

      assert {:ok, %ParsedBook{} = parsed_book} = Books.update_parsed_book(parsed_book, update_attrs)
      assert parsed_book.title == "some updated title"
      assert parsed_book.metadata == %{}
      assert parsed_book.language == "some updated language"
      assert parsed_book.file_size == 43
      assert parsed_book.source_file_path == "some updated source_file_path"
      assert parsed_book.authors == ["option1"]
      assert parsed_book.source_format == "some updated source_format"
      assert parsed_book.file_hash == "some updated file_hash"
      assert parsed_book.isbn == "some updated isbn"
      assert parsed_book.publisher == "some updated publisher"
      assert parsed_book.publication_date == ~D[2025-12-17]
      assert parsed_book.total_pages == 43
      assert parsed_book.word_count == 43
      assert parsed_book.table_of_contents == %{}
      assert parsed_book.parsed_at == ~U[2025-12-17 15:23:00Z]
      assert parsed_book.embedding_status == :completed
    end

    test "update_parsed_book/2 with invalid data returns error changeset" do
      parsed_book = parsed_book_fixture()
      assert {:error, %Ecto.Changeset{}} = Books.update_parsed_book(parsed_book, @invalid_attrs)
      assert parsed_book == Books.get_parsed_book!(parsed_book.id)
    end

    test "delete_parsed_book/1 deletes the parsed_book" do
      parsed_book = parsed_book_fixture()
      assert {:ok, %ParsedBook{}} = Books.delete_parsed_book(parsed_book)
      assert_raise Ecto.NoResultsError, fn -> Books.get_parsed_book!(parsed_book.id) end
    end

    test "change_parsed_book/1 returns a parsed_book changeset" do
      parsed_book = parsed_book_fixture()
      assert %Ecto.Changeset{} = Books.change_parsed_book(parsed_book)
    end
  end

  describe "chunks" do
    alias Cake.Books.Chunk

    import Cake.BooksFixtures

    @invalid_attrs %{text: nil, page_number: nil, chunk_index: nil, section_title: nil, word_count: nil, char_count: nil}

    test "list_chunks/0 returns all chunks" do
      chunk = chunk_fixture()
      assert Books.list_chunks() == [chunk]
    end

    test "get_chunk!/1 returns the chunk with given id" do
      chunk = chunk_fixture()
      assert Books.get_chunk!(chunk.id) == chunk
    end

    test "create_chunk/1 with valid data creates a chunk" do
      parsed_book = parsed_book_fixture()
      valid_attrs = %{text: "some text", page_number: 42, chunk_index: 42, section_title: "some section_title", word_count: 42, char_count: 42, parsed_book_id: parsed_book.id}

      assert {:ok, %Chunk{} = chunk} = Books.create_chunk(valid_attrs)
      assert chunk.text == "some text"
      assert chunk.page_number == 42
      assert chunk.chunk_index == 42
      assert chunk.section_title == "some section_title"
      assert chunk.word_count == 42
      assert chunk.char_count == 42
    end

    test "create_chunk/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Books.create_chunk(@invalid_attrs)
    end

    test "update_chunk/2 with valid data updates the chunk" do
      chunk = chunk_fixture()
      update_attrs = %{text: "some updated text", page_number: 43, chunk_index: 43, section_title: "some updated section_title", word_count: 43, char_count: 43}

      assert {:ok, %Chunk{} = chunk} = Books.update_chunk(chunk, update_attrs)
      assert chunk.text == "some updated text"
      assert chunk.page_number == 43
      assert chunk.chunk_index == 43
      assert chunk.section_title == "some updated section_title"
      assert chunk.word_count == 43
      assert chunk.char_count == 43
    end

    test "update_chunk/2 with invalid data returns error changeset" do
      chunk = chunk_fixture()
      assert {:error, %Ecto.Changeset{}} = Books.update_chunk(chunk, @invalid_attrs)
      assert chunk == Books.get_chunk!(chunk.id)
    end

    test "delete_chunk/1 deletes the chunk" do
      chunk = chunk_fixture()
      assert {:ok, %Chunk{}} = Books.delete_chunk(chunk)
      assert_raise Ecto.NoResultsError, fn -> Books.get_chunk!(chunk.id) end
    end

    test "change_chunk/1 returns a chunk changeset" do
      chunk = chunk_fixture()
      assert %Ecto.Changeset{} = Books.change_chunk(chunk)
    end
  end
end
