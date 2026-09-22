defmodule Cake.Books.PipelineTest do
  use Cake.DataCase, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Pipeline
  alias Cake.FailedIngests.FailedIngest

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

  # A non-fatal failure recorded by a concurrent Books run with the same
  # format pipeline and embedding model, i.e. the same identity as run_ingest/1.
  defp insert_sibling_run_failure(path) do
    {:ok, failure} =
      Cake.FailedIngests.create_failed_ingest(%{
        run_id: Ecto.UUID.generate(),
        pipeline_behaviour: "Cake.Books.Pipeline",
        pipeline_implementation: "Cake.TestBooksPipeline",
        step: "books.parse",
        version: "test-model",
        error_text: "boom",
        input_identifier: path,
        pipeline_fatal: false
      })

    failure
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

  # -------------------------------------------------------------------
  # validate_paths/1 — the eager, run-level fallible step
  # -------------------------------------------------------------------

  describe "validate_paths/1" do
    test "returns {:ok, paths} for a non-empty list of non-blank string keys" do
      paths = ["books/a.pdf", "books/b.pdf"]

      assert {:ok, ^paths} = Pipeline.validate_paths(paths)
    end

    test "rejects an empty list as :no_paths" do
      assert {:error, :validate_paths, :no_paths} = Pipeline.validate_paths([])
    end

    test "rejects blank and non-string keys, reporting every invalid key" do
      paths = ["books/a.pdf", "", "   ", nil, :atom_key]

      assert {:error, :validate_paths, {:invalid_paths, ["", "   ", nil, :atom_key]}} =
               Pipeline.validate_paths(paths)
    end

    test "rejects non-UTF-8 keys byte-for-byte, in input order" do
      invalid_byte = <<"books/", 255, ".pdf">>
      truncated_sequence = <<0xC3>>
      paths = ["books/a.pdf", invalid_byte, "books/b.pdf", truncated_sequence]

      assert {:error, :validate_paths, {:invalid_paths, [^invalid_byte, ^truncated_sequence]}} =
               Pipeline.validate_paths(paths)
    end

    test "rejects keys containing a NUL byte, unchanged" do
      nul_key = <<"books/a", 0, ".pdf">>

      assert {:error, :validate_paths, {:invalid_paths, [^nul_key]}} =
               Pipeline.validate_paths(["books/a.pdf", nul_key])
    end
  end

  # -------------------------------------------------------------------
  # ingest/4 — pipeline-fatal errors route through handle_ingest_error/2
  # -------------------------------------------------------------------

  describe "ingest/4 pipeline-fatal errors" do
    test "returns {:error, {:validate_paths, reason}} for an empty path list" do
      capture_log(fn ->
        assert {:error, {:validate_paths, :no_paths}} = run_ingest([])
      end)
    end

    test "returns {:error, {:validate_paths, reason}} when any key is invalid" do
      capture_log(fn ->
        assert {:error, {:validate_paths, {:invalid_paths, [""]}}} =
                 run_ingest(["books/a.pdf", ""])
      end)
    end

    test "rejects a non-UTF-8 key and persists the fatal row" do
      invalid_key = <<"books/", 255, ".pdf">>

      capture_log(fn ->
        assert {:error, {:validate_paths, {:invalid_paths, [^invalid_key]}}} =
                 run_ingest(["books/a.pdf", invalid_key])
      end)

      assert [failure] = Repo.all(FailedIngest)
      assert failure.step == "validate_paths"
      assert failure.pipeline_fatal == true
      assert failure.error_text == inspect({:invalid_paths, [invalid_key]})
    end

    test "rejects a NUL-containing key and persists the fatal row unaltered" do
      nul_key = <<"books/a", 0, ".pdf">>

      capture_log(fn ->
        assert {:error, {:validate_paths, {:invalid_paths, [^nul_key]}}} =
                 run_ingest(["books/a.pdf", nul_key])
      end)

      assert [failure] = Repo.all(FailedIngest)
      assert failure.step == "validate_paths"
      assert failure.pipeline_fatal == true
      # inspect/1 escapes the NUL as `\0`, so sanitize_text_fields/1 has
      # nothing to strip and the persisted error names the key exactly.
      assert failure.error_text == inspect({:invalid_paths, [nul_key]})
    end

    test "logs the fatal error with the pipeline behaviour and step" do
      log = capture_log(fn -> run_ingest([]) end)

      assert log =~ "[Cake.Books.Pipeline] Pipeline-fatal error at validate_paths"
      assert log =~ ":no_paths"
    end

    test "persists a pipeline-fatal FailedIngest row tagged with the Context fields" do
      capture_log(fn -> run_ingest([]) end)

      assert [failure] = Repo.all(FailedIngest)
      assert failure.pipeline_behaviour == "Cake.Books.Pipeline"
      assert failure.pipeline_implementation == "Cake.TestBooksPipeline"
      assert failure.pipeline_fatal == true
      assert failure.step == "validate_paths"
      # Books has no source version, so its failures record the embedding
      # model as their version for provenance.
      assert failure.version == "test-model"
      assert failure.error_text == inspect(:no_paths)
    end

    test "short-circuits before any valid key is loaded or persisted" do
      book = make_book("Valid Book", "valid")
      path = book.source_file_path
      register_test_books([{path, {book, [make_chunk("Valid chunk")]}}])

      test_pid = self()

      stub(Cake.Embeddings.Mock, :embed, fn :openai, _input, "test-model" ->
        send(test_pid, :embed_called)
        successful_embed_response()
      end)

      capture_log(fn -> run_ingest([path, nil]) end)

      assert persisted_books() == []
      refute_received :embed_called
    end

    test "ingest_with_sweep/5 returns the fatal error unchanged" do
      capture_log(fn ->
        assert {:error, {:validate_paths, :no_paths}} =
                 Pipeline.ingest_with_sweep(:openai, Cake.TestBooksPipeline, "test-model", [])
      end)
    end
  end

  # -------------------------------------------------------------------
  # Item-level FailedIngest provenance — keyed by embedding model
  # -------------------------------------------------------------------

  describe "ingest/4 item-level failure persistence" do
    test "persists an item-level failure keyed by the embedding model" do
      path = "/test/unregistered.pdf"

      capture_log(fn -> run_ingest([path]) end)

      assert [failure] = Repo.all(FailedIngest)
      assert failure.pipeline_behaviour == "Cake.Books.Pipeline"
      assert failure.pipeline_implementation == "Cake.TestBooksPipeline"
      assert failure.step == "books.parse"
      assert failure.version == "test-model"
      assert failure.input_identifier == path
      assert failure.pipeline_fatal == false
      assert {:ok, _} = Ecto.UUID.cast(failure.run_id)
    end

    test "does not count a concurrent run's failures in its own summary" do
      # A sibling run with the same identity records a failure while this run
      # is in flight (from inside the embed step, so it lands between the
      # run's start and its finalize). This run's summary must not include it.
      book = make_book("Concurrent Book", "concurrent")
      path = book.source_file_path
      register_test_books([{path, {book, [make_chunk("Concurrent chunk")]}}])

      stub(Cake.Embeddings.Mock, :embed, fn :openai, _input, "test-model" ->
        insert_sibling_run_failure("/test/other.pdf")
        {:error, "boom"}
      end)

      capture_log(fn ->
        assert {:error, {:no_items_ingested, %{indexed: 0, failed: 1}}} = run_ingest([path])
      end)
    end

    test "ingest_with_sweep/5 leaves another run's failures alone" do
      # The sibling's failure is retryable (its book is registered), so a
      # sweep that reached it would resolve and delete it.
      other_book = make_book("Other Run Book", "other")
      other_path = other_book.source_file_path
      book = make_book("This Run Book", "this")
      path = book.source_file_path

      register_test_books([
        {other_path, {other_book, [make_chunk("Other chunk")]}},
        {path, {book, [make_chunk("This chunk")]}}
      ])

      sibling_failure = insert_sibling_run_failure(other_path)

      stub(Cake.Embeddings.Mock, :embed, fn :openai, _input, "test-model" ->
        successful_embed_response()
      end)

      capture_log(fn ->
        Pipeline.ingest_with_sweep(:openai, Cake.TestBooksPipeline, "test-model", [path])
      end)

      assert [%FailedIngest{id: id}] = Repo.all(FailedIngest)
      assert id == sibling_failure.id
      assert [%ParsedBook{title: "This Run Book"}] = persisted_books()
    end

    test "reports a run in which every item failed as :no_items_ingested" do
      capture_log(fn ->
        assert {:error, {:no_items_ingested, %{indexed: 0, failed: 1}}} =
                 run_ingest(["/test/unregistered.pdf"])
      end)
    end

    test "ingest_with_sweep/5 finds and resolves a failure recorded during the run" do
      book = make_book("Sweep Book", "sweep")
      path = book.source_file_path
      register_test_books([{path, {book, [make_chunk("Sweep chunk")]}}])

      Cake.Embeddings.Mock
      |> expect(:embed, fn :openai, _input, "test-model" -> {:error, "transient"} end)
      |> expect(:embed, fn :openai, _input, "test-model" -> successful_embed_response() end)

      capture_log(fn ->
        Pipeline.ingest_with_sweep(:openai, Cake.TestBooksPipeline, "test-model", [path])
      end)

      assert Repo.all(FailedIngest) == []
      assert [chunk] = Repo.all(Chunk)
      assert chunk.embedding == @fake_embedding
    end
  end
end
