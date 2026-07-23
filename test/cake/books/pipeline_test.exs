defmodule Cake.Books.PipelineTest do
  use Cake.DataCase, async: true

  import Mox

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Pipeline

  setup :verify_on_exit!

  # -------------------------------------------------------------------
  # munge_persisted_stream/1 (existing tests, unchanged)
  # -------------------------------------------------------------------

  describe "munge_persisted_stream/1" do
    test "unwraps {:ok, {:ok, value}} into {:ok, value}" do
      book = %ParsedBook{title: "T"}
      chunks = [%Chunk{text: "c"}]

      assert {:ok, {^book, ^chunks}} =
               Pipeline.munge_persisted_stream({:ok, {:ok, {book, chunks}}})
    end

    test "unwraps {:ok, {:error, {path, reason}}} into {:error, {path, stringified}}" do
      assert {:error, {"/tmp/x.pdf", reason}} =
               Pipeline.munge_persisted_stream({:ok, {:error, {"/tmp/x.pdf", :some_reason}}})

      assert reason =~ "some_reason"
    end

    test "unwraps {:ok, {:error, reason}} into {:error, reason}" do
      assert {:error, :boom} = Pipeline.munge_persisted_stream({:ok, {:error, :boom}})
    end

    test "handles {:exit, {input_with_book, reason}}" do
      book = %ParsedBook{source_file_path: "/tmp/test.pdf"}
      chunks = [%Chunk{text: "c"}]

      assert {:error, {"/tmp/test.pdf", _}} =
               Pipeline.munge_persisted_stream({:exit, {{book, chunks}, :killed}})
    end

    test "handles {:exit, {non_book_input, reason}}" do
      assert {:error, {nil, _}} =
               Pipeline.munge_persisted_stream({:exit, {"unknown", :killed}})
    end
  end

  # -------------------------------------------------------------------
  # embedding_status lifecycle
  # -------------------------------------------------------------------

  @embedding_dim 3
  @fake_embedding List.duplicate(0.1, @embedding_dim)

  defp successful_embed_response do
    {:ok, %{usage: %{}, struct: nil, attrs: %{embedding: @fake_embedding}}}
  end

  defp make_book(title, file_hash) do
    %ParsedBook{
      title: title,
      source_file_path: "/test/#{file_hash}.pdf",
      source_format: "test",
      file_hash: file_hash,
      file_size: 100,
      word_count: 10,
      parsed_at: DateTime.truncate(DateTime.utc_now(), :second),
      embedding_status: :pending
    }
  end

  defp make_chunk(text, section_title \\ "Section") do
    word_count = length(String.split(text, ~r/\s+/, trim: true))

    %Chunk{
      text: text,
      chunk_index: 0,
      section_title: section_title,
      word_count: word_count,
      char_count: String.length(text)
    }
  end

  defp register_test_books(books_with_paths) do
    Process.put(:test_books_pipeline_books, books_with_paths)
  end

  defp run_ingest(paths) do
    Pipeline.ingest(:openai, Cake.TestBooksPipeline, "test-model", paths)
  end

  defp reload_book(book_id) do
    Books.get_parsed_book!(book_id)
  end

  defp persisted_books do
    Books.list_parsed_books()
  end

  describe "embedding_status lifecycle" do
    test "sets :completed when all chunks embed successfully" do
      book = make_book("Good Book", "hash_good_#{System.unique_integer([:positive])}")
      chunk1 = make_chunk("First chunk of text")
      chunk2 = make_chunk("Second chunk of text")
      path = book.source_file_path

      register_test_books([{path, {book, [chunk1, chunk2]}}])

      expect(Cake.Embeddings.Mock, :embed, 2, fn :openai, _input, "test-model" ->
        successful_embed_response()
      end)

      assert {:ok, _summary} = run_ingest([path])

      [persisted] = persisted_books()
      assert reload_book(persisted.id).embedding_status == :completed
    end

    test "sets :failed when any chunk fails to embed" do
      book = make_book("Bad Book", "hash_bad_#{System.unique_integer([:positive])}")
      chunk1 = make_chunk("This chunk will embed fine")
      chunk2 = make_chunk("This chunk will fail")
      path = book.source_file_path

      register_test_books([{path, {book, [chunk1, chunk2]}}])

      expect(Cake.Embeddings.Mock, :embed, 2, fn :openai, %{input: input}, "test-model" ->
        if input =~ "will fail" do
          {:error, "API error: rate limited"}
        else
          successful_embed_response()
        end
      end)

      assert {:ok, _summary} = run_ingest([path])

      [persisted] = persisted_books()
      assert reload_book(persisted.id).embedding_status == :failed
    end

    test "sets :processing before embedding begins" do
      book = make_book("Processing Book", "hash_proc_#{System.unique_integer([:positive])}")
      chunk = make_chunk("Only chunk")
      path = book.source_file_path

      register_test_books([{path, {book, [chunk]}}])

      test_pid = self()

      expect(Cake.Embeddings.Mock, :embed, 1, fn :openai, _input, "test-model" ->
        [persisted] = persisted_books()
        send(test_pid, {:status_during_embed, reload_book(persisted.id).embedding_status})
        successful_embed_response()
      end)

      assert {:ok, _summary} = run_ingest([path])

      assert_received {:status_during_embed, :processing}
    end

    test "handles multiple books with mixed outcomes independently" do
      book_a = make_book("Book A", "hash_a_#{System.unique_integer([:positive])}")
      book_b = make_book("Book B", "hash_b_#{System.unique_integer([:positive])}")

      chunk_a = make_chunk("Book A chunk")
      chunk_b = make_chunk("Book B chunk will fail")

      path_a = book_a.source_file_path
      path_b = book_b.source_file_path

      register_test_books([
        {path_a, {book_a, [chunk_a]}},
        {path_b, {book_b, [chunk_b]}}
      ])

      expect(Cake.Embeddings.Mock, :embed, 2, fn :openai, %{input: input}, "test-model" ->
        if input =~ "will fail" do
          {:error, "API error"}
        else
          successful_embed_response()
        end
      end)

      assert {:ok, _summary} = run_ingest([path_a, path_b])

      all_books = Enum.sort_by(persisted_books(), & &1.title)

      assert [persisted_a, persisted_b] = all_books
      assert reload_book(persisted_a.id).embedding_status == :completed
      assert reload_book(persisted_b.id).embedding_status == :failed
    end
  end
end
