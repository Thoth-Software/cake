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
  import Cake.PdfFixtures, only: [fixture_binary: 1]
  import Mox

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Pdf
  alias Cake.Books.Pipeline
  alias Cake.FailedIngests.FailedIngest
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
end
