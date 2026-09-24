defmodule Cake.Books.PipelineIntegrationTest do
  @moduledoc """
  The Books ingestion pipeline end to end (#248): a fixture PDF staged
  through the Disk storage adapter, `Cake.Books.Pipeline.ingest/4` over the
  real Rustler NIF, real `ParsedBook` and `Chunk` rows in Postgres, real
  documents in the `chunks_of_books` collection of a real OpenSearch node,
  and `Cake.Search.search_chunks/4` finding the chunk again.

  Only the embedding provider is substituted: `Cake.Embeddings.Mock` hands
  out `deterministic_embedding/1` vectors, so a query embedded the same way
  is an exact vector match (cosine 1.0) for the chunk it was derived from.

  `async: false`: the pipeline indexes into the GDS's fixed collection name
  (inside the `cake_test` namespace) and the storage adapter is application
  config, both global to the VM. Runs with `mix test --only integration`.
  """

  use Cake.SearchIntegrationCase, async: false

  import Cake.IngestIntegrationHelpers
  import Cake.PdfFixtures, only: [fixture_binary: 1, parse_fixture: 1]
  import Mox

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Pdf
  alias Cake.Books.Pipeline
  alias Cake.FailedIngests.FailedIngest
  alias Cake.Pipelines
  alias Cake.Repo
  alias Cake.Search
  alias Cake.Search.Hit
  alias Cake.Search.Result

  setup :verify_on_exit!
  setup :stage_book_storage!

  setup do
    ensure_collection!(ParsedBook)
    :ok
  end

  defp ids(hits_or_structs), do: Enum.map(hits_or_structs, & &1.id)

  defp ingest(keys), do: Pipeline.ingest(:openai, Pdf.Pipeline, embedding_model(), keys)

  defp failures, do: FailedIngest |> Repo.all() |> Enum.sort_by(& &1.step)

  describe "happy path" do
    test "a fixture PDF becomes a searchable chunk: NIF → Postgres → OpenSearch → search" do
      key = stage_fixture!(:multi_page)
      stub_embeddings()

      assert {:ok, %{indexed: 3, failed: 0, message: message}} =
               Pipeline.ingest(:openai, Pdf.Pipeline, embedding_model(), [key])

      assert message == Pdf.Pipeline.success_message()

      # Postgres: the book row from the NIF's extraction, and one chunk per
      # page, each carrying the vector the embedding stub handed out for the
      # exact input the pipeline embeds (section title, blank line, text).
      assert [%ParsedBook{} = book] = Books.list_parsed_books()
      assert book.source_file_path == key
      assert book.title == "Cake Fixture Book"
      assert book.source_format == "pdf"
      assert book.total_pages == 3
      assert book.embedding_status == :completed

      assert book.file_hash ==
               Base.encode16(:crypto.hash(:sha256, fixture_binary(:multi_page)), case: :lower)

      chunks = chunks_in_order(book)
      assert Enum.map(chunks, & &1.chunk_index) == [0, 1, 2]
      assert Enum.map(chunks, & &1.page_number) == [1, 2, 3]
      assert Enum.all?(chunks, &(&1.embedding == deterministic_embedding(embed_input(&1))))

      assert Repo.all(FailedIngest) == []

      # OpenSearch: the chunks landed in the GDS's collection, and the public
      # search API finds them by keyword, by vector, and hydrated as Results.
      refresh!(ParsedBook.collection_name())
      [_first, second, _third] = chunks
      second_id = second.id

      assert {:ok, [%Hit{id: ^second_id} | _] = hits} =
               Search.search_chunks(:keyword, "second page continues", nil, gds: ParsedBook)

      assert MapSet.subset?(MapSet.new(ids(hits)), MapSet.new(ids(chunks)))

      query_vector = deterministic_embedding(embed_input(second))

      assert {:ok, [%Hit{id: ^second_id, score: 1.0} | _]} =
               Search.search_chunks(:vector, "", query_vector, gds: ParsedBook)

      # Results come back in chunk order (neighbor expansion re-sorts them;
      # ranking is the conversation layer's job), so find the hit by id.
      assert {:ok, results} =
               Search.search_chunks_with_context(:hybrid, "second page", query_vector, 0,
                 gds: ParsedBook
               )

      assert %Result{retrieval_unit: %Chunk{} = unit, hit_source: :search, backend_score: score} =
               Enum.find(results, &(&1.retrieval_unit.id == second_id))

      assert is_float(score) and score > 0.0
      assert %ParsedBook{id: book_id} = unit.parsed_book
      assert book_id == book.id
    end
  end

  describe "contracts: dedup on file_hash" do
    test "re-ingesting the same PDF under a new key keeps one book, re-embeds and re-indexes its chunks" do
      stub_embeddings()
      first_key = stage_fixture!(:multi_page)
      second_key = stage_fixture!(:multi_page)

      assert {:ok, %{indexed: 3, failed: 0}} = ingest([first_key])
      assert [%ParsedBook{id: book_id} = book] = Books.list_parsed_books()
      chunks = chunks_in_order(book)

      # Same bytes, different key: Persistence finds the file_hash and hands
      # back the existing book and chunks, which are then embedded and
      # indexed again. The row keeps the key it was first ingested under.
      assert {:ok, %{indexed: 3, failed: 0}} = ingest([second_key])

      assert [
               %ParsedBook{
                 id: ^book_id,
                 source_file_path: ^first_key,
                 embedding_status: :completed
               }
             ] =
               Books.list_parsed_books()

      assert ids(chunks_in_order(book)) == ids(chunks)
      assert Repo.all(FailedIngest) == []
      assert Enum.sort(indexed_ids!(ParsedBook)) == Enum.sort(ids(chunks))
    end
  end

  describe "contracts: honest summaries" do
    test "one good and one unparseable PDF is a partial run: the good book is indexed, the failure persisted" do
      stub_embeddings()
      good = stage_fixture!(:multi_page)
      bad = stage_fixture!(:truncated)

      assert {:ok, %{indexed: 3, failed: 1}} = ingest([good, bad])

      # The NIF rejects the truncated file; parse/1 raises on that, and the
      # orchestrator records it as a run-scoped, non-fatal item failure
      # keyed by the storage key.
      assert [%FailedIngest{} = failure] = Repo.all(FailedIngest)
      assert failure.step == "books.parse"
      assert failure.input_identifier == bad
      assert failure.pipeline_fatal == false
      assert failure.error_text =~ "PDF load failed"
      assert {:ok, _uuid} = Ecto.UUID.cast(failure.run_id)

      assert [%ParsedBook{source_file_path: ^good} = book] = Books.list_parsed_books()
      assert Enum.sort(indexed_ids!(ParsedBook)) == Enum.sort(ids(chunks_in_order(book)))
    end

    test "a run in which every PDF fails is {:error, {:no_items_ingested, summary}} and indexes nothing" do
      stub_embeddings()
      bad = stage_fixture!(:truncated)

      missing =
        Cake.Books.Adapters.build_key(
          "books",
          "never_staged_#{System.unique_integer([:positive])}.pdf"
        )

      assert {:error, {:no_items_ingested, %{indexed: 0, failed: 2}}} = ingest([bad, missing])

      assert [
               %FailedIngest{step: "books.load_binary", input_identifier: ^missing},
               %FailedIngest{step: "books.parse", input_identifier: ^bad}
             ] = failures()

      assert Books.list_parsed_books() == []
      assert indexed_ids!(ParsedBook) == []
    end
  end

  describe "contracts: embedding_status" do
    # The persisted row starts :pending: Pdf.Pipeline.parse/1 builds the book
    # in that state (pinned in Cake.Books.Pdf.PipelineIntegrationTest) and
    # Persistence inserts it verbatim. The transitions from there are
    # observed here from inside the embedding stub, which runs while the
    # pipeline embeds the book's chunks.
    test "a book is :processing while its chunks embed and :completed once they all have" do
      key = stage_fixture!(:multi_page)
      test_pid = self()

      stub_embeddings(fn input ->
        [%ParsedBook{embedding_status: status}] = Books.list_parsed_books()
        send(test_pid, {:status_while_embedding, status})
        deterministic_embedding(input)
      end)

      assert {:ok, %{indexed: 3, failed: 0}} = ingest([key])

      for _chunk <- 1..3, do: assert_received({:status_while_embedding, :processing})
      refute_received {:status_while_embedding, _other}

      assert [%ParsedBook{embedding_status: :completed}] = Books.list_parsed_books()
    end

    test "a book with a chunk that fails to embed is :failed, the failure keyed by the chunk id, the rest indexed" do
      key = stage_fixture!(:multi_page)
      {_book, [_first, second, _third]} = parse_fixture(:multi_page)
      failing_input = embed_input(second)

      stub_embeddings(fn
        ^failing_input -> {:error, "rate limited"}
        input -> deterministic_embedding(input)
      end)

      assert {:ok, %{indexed: 2, failed: 1}} = ingest([key])

      assert [%ParsedBook{embedding_status: :failed} = book] = Books.list_parsed_books()
      [first, persisted_second, third] = chunks_in_order(book)
      assert persisted_second.embedding == nil
      assert first.embedding == deterministic_embedding(embed_input(first))

      assert [%FailedIngest{step: "books.embed", pipeline_fatal: false} = failure] =
               Repo.all(FailedIngest)

      assert failure.input_identifier == persisted_second.id
      assert failure.error_text =~ "rate limited"

      assert Enum.sort(indexed_ids!(ParsedBook)) == Enum.sort([first.id, third.id])
    end
  end

  describe "contracts: pipeline-fatal path (#258, PR #265)" do
    test "an empty key list is fatal: a pipeline_fatal FailedIngest row carries the run's run_id, nothing runs" do
      assert {:error, {:validate_paths, :no_paths}} = ingest([])

      assert [%FailedIngest{pipeline_fatal: true} = failure] = Repo.all(FailedIngest)
      assert failure.step == "validate_paths"
      assert failure.pipeline_behaviour == "Cake.Books.Pipeline"
      assert failure.pipeline_implementation == "Cake.Books.Pdf.Pipeline"
      assert failure.version == embedding_model()
      assert failure.error_text == inspect(:no_paths)
      assert {:ok, _uuid} = Ecto.UUID.cast(failure.run_id)

      # A fatal row is provenance, not a retry candidate: the run-scoped
      # sweep and count never see it.
      assert Cake.FailedIngests.list_failed_ingests_for_run(failure.run_id) == []

      assert Books.list_parsed_books() == []
      assert indexed_ids!(ParsedBook) == []
    end

    test "an invalid key among valid ones is fatal before any valid key is loaded" do
      good = stage_fixture!(:multi_page)

      assert {:error, {:validate_paths, {:invalid_paths, ["   "]}}} = ingest([good, "   "])

      assert [%FailedIngest{pipeline_fatal: true, step: "validate_paths"}] =
               Repo.all(FailedIngest)

      assert Books.list_parsed_books() == []
      assert indexed_ids!(ParsedBook) == []
    end
  end

  describe "sweep and retry (run-scoped per PR #265)" do
    defp ingest_with_sweep(keys, opts \\ []) do
      Pipeline.ingest_with_sweep(:openai, Pdf.Pipeline, embedding_model(), keys, opts)
    end

    test "a chunk whose embed failed once is re-embedded and re-indexed by the sweep, its failure deleted" do
      key = stage_fixture!(:multi_page)
      {_book, [_first, second, _third]} = parse_fixture(:multi_page)
      stub_embeddings(once_then_deterministic(%{embed_input(second) => {:error, "transient"}}))

      # The return is the run's own honest summary; the sweep's outcome is
      # logged, never folded into it.
      assert {:ok, %{indexed: 2, failed: 1}} = ingest_with_sweep([key])

      assert Repo.all(FailedIngest) == []
      assert [%ParsedBook{} = book] = Books.list_parsed_books()
      [first, persisted_second, third] = chunks_in_order(book)
      assert persisted_second.embedding == deterministic_embedding(embed_input(persisted_second))

      assert Enum.sort(indexed_ids!(ParsedBook)) ==
               Enum.sort([first.id, persisted_second.id, third.id])

      second_id = persisted_second.id
      query_vector = deterministic_embedding(embed_input(persisted_second))

      assert {:ok, [%Hit{id: ^second_id, score: 1.0} | _]} =
               Search.search_chunks(:vector, "", query_vector, gds: ParsedBook)

      # Deliberately unpinned: the book's embedding_status is still :failed
      # here — the run set it, and retry_from_chunk never revisits it after
      # resolving the chunk. Whether a sweep should update it is a question
      # for its own issue, not something this suite decides (#248).
    end

    test "a chunk the index rejected once (wrong-dimension vector) is re-embedded and re-indexed by the sweep" do
      key = stage_fixture!(:multi_page)
      {_book, [_first, second, _third]} = parse_fixture(:multi_page)
      stub_embeddings(once_then_deterministic(%{embed_input(second) => [1.0, 0.0, 0.0]}))

      # The embed "succeeds", the chunk is updated with the bad vector, and
      # the real index rejects it: a "search_backend.index" failure keyed by
      # the chunk id, which retry_from_chunk resolves by embedding again.
      assert {:ok, %{indexed: 2, failed: 1}} = ingest_with_sweep([key])

      assert Repo.all(FailedIngest) == []
      assert [%ParsedBook{} = book] = Books.list_parsed_books()
      [first, persisted_second, third] = chunks_in_order(book)
      assert persisted_second.embedding == deterministic_embedding(embed_input(persisted_second))

      assert Enum.sort(indexed_ids!(ParsedBook)) ==
               Enum.sort([first.id, persisted_second.id, third.id])
    end

    test "an unresolvable failure remains after max_sweeps with its run-scoped count intact; resolvable ones are deleted" do
      key = stage_fixture!(:multi_page)
      {_book, [_first, second, third]} = parse_fixture(:multi_page)
      permanent = embed_input(third)
      transient = once_then_deterministic(%{embed_input(second) => {:error, "transient"}})

      stub_embeddings(fn
        ^permanent -> {:error, "permanent"}
        input -> transient.(input)
      end)

      assert {:ok, %{indexed: 1, failed: 2}} = ingest_with_sweep([key], max_sweeps: 2)

      assert [%ParsedBook{} = book] = Books.list_parsed_books()
      [first, persisted_second, persisted_third] = chunks_in_order(book)

      assert [%FailedIngest{step: "books.embed", pipeline_fatal: false} = remaining] =
               Repo.all(FailedIngest)

      assert remaining.input_identifier == persisted_third.id
      assert remaining.error_text =~ "permanent"
      assert Pipelines.count_failures(%Pipelines.Context{run_id: remaining.run_id}) == 1

      assert persisted_second.embedding == deterministic_embedding(embed_input(persisted_second))
      assert persisted_third.embedding == nil
      assert Enum.sort(indexed_ids!(ParsedBook)) == Enum.sort([first.id, persisted_second.id])
    end

    test "failures recorded by another run of the same pipeline are untouched by this run's sweep" do
      # An earlier run's book, so the other run's failure names a chunk a
      # retry could resolve — a sweep that reached it would delete it.
      stub_embeddings()
      earlier_key = stage_fixture!(:no_title)
      assert {:ok, %{indexed: 2, failed: 0}} = ingest([earlier_key])
      assert [%ParsedBook{} = earlier_book] = Books.list_parsed_books()
      [earlier_chunk | _rest] = chunks_in_order(earlier_book)

      other_run = Pipelines.build_context(Pipeline, Pdf.Pipeline, embedding_model())

      {:ok, %FailedIngest{id: other_id}} =
        Pipelines.log_and_persist_failure(other_run, "books.embed", {earlier_chunk.id, "theirs"})

      # This run records one transient failure of its own and sweeps it up.
      key = stage_fixture!(:multi_page)
      {_book, [_first, second, _third]} = parse_fixture(:multi_page)
      stub_embeddings(once_then_deterministic(%{embed_input(second) => {:error, "transient"}}))

      assert {:ok, %{indexed: 2, failed: 1}} = ingest_with_sweep([key])

      assert [%FailedIngest{id: ^other_id, run_id: other_run_id}] = Repo.all(FailedIngest)
      assert other_run_id == other_run.run_id
      assert Pipelines.count_failures(other_run) == 1
    end
  end
end
