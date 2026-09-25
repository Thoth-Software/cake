defmodule Cake.IngestIntegrationHelpers do
  @moduledoc """
  Helpers for the end-to-end ingestion tests (#248): a fixture PDF in, a
  searchable chunk out, through the real NIF, real Postgres, the
  `Cake.Embeddings.Mock` collaborator, and a real OpenSearch node.

  Built on `Cake.SearchIntegrationCase` (the real cluster, the `cake_test`
  namespace, `unit_vector/1`) and `Cake.PdfFixtures` (the fixture PDFs).
  Import it per test module, like the fixture modules.

  ## What is real and what is substituted

  Only the embedding provider is substituted, and deterministically:
  `stub_embeddings/1` answers every `Cake.Embeddings.Mock.embed/3` call
  from a function of the input text, by default `deterministic_embedding/1`,
  the unit vector on the axis the text hashes to. A query embedded the same
  way is therefore an exact vector match (cosine 1.0) for the record it was
  derived from, so ranking can be pinned without tolerances. `embed_input/1`
  builds the exact string the pipelines embed for a record (title, blank
  line, text), so a test never has to know that convention.

  ## Global state these helpers manage

  Two things the pipelines read are global to the VM, which is why every
  test module using these helpers is `async: false`:

    * the storage adapter config: `stage_book_storage!/1` (a setup callback)
      points `:book_storage_adapter` at `Cake.Books.Adapters.Disk` under a
      fresh temp root, and `stage_fixture!/1` writes a fixture through that
      adapter and returns the storage key; both are restored/removed on exit;
    * the GDS's fixed collection name (`chunks_of_books`, `docs`), which the
      pipelines index into and `Cake.Search` reads from: `ensure_collection!/1`
      creates it on the real node with the production mapping if it is
      missing, empties it, and empties it again on exit. The collection is
      left in place: `Cake.Search.Deployment`'s boot task creates the same
      names in the namespace on its own schedule, and tolerating its
      existence on both sides keeps the two from racing.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Cake.Books.Adapters
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Documents.ParsedDocument
  alias Cake.Repo
  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment
  alias Cake.SearchIntegrationCase

  # OpenSearch's default index.max_result_window: the most one search returns.
  @max_result_window 10_000

  @typedoc "What `stub_embeddings/1`'s function answers for one input: a vector, or the provider's error."
  @type embedding_response :: [float()] | {:error, String.t()}

  @doc """
  Setup callback: routes book storage to `Cake.Books.Adapters.Disk` under a
  fresh temp root for the duration of the test, restoring the previous
  adapter config and removing the root on exit. Returns the root in the
  context as `:book_storage_root`.
  """
  @spec stage_book_storage!(map()) :: %{book_storage_root: Path.t()}
  def stage_book_storage!(_context) do
    root =
      Path.join(System.tmp_dir!(), "cake_ingest_it_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    previous_adapter = Application.get_env(:cake, :book_storage_adapter)
    previous_root = Application.get_env(:cake, :book_storage_root)
    Application.put_env(:cake, :book_storage_adapter, Adapters.Disk)
    Application.put_env(:cake, :book_storage_root, root)

    on_exit(fn ->
      restore_env(:book_storage_adapter, previous_adapter)
      restore_env(:book_storage_root, previous_root)
      File.rm_rf!(root)
    end)

    %{book_storage_root: root}
  end

  @doc """
  Makes the GDS's fixed collection (`gds.collection_name/0`) exist and be
  empty on the real node for this test, and empties it again on exit. The
  mapping is the one production would create: the schema paired with the
  GDS in the `:search_collections` config, through
  `Cake.Search.Backend.OpenSearch.build_mapping/1`. Raises if the GDS is not
  configured or the node refuses.
  """
  @spec ensure_collection!(module()) :: :ok
  def ensure_collection!(gds) when is_atom(gds) do
    collection = gds.collection_name()
    mapping = OpenSearch.build_mapping(mapping_schema_for!(gds))

    case OpenSearch.create_collection(collection, mapping) do
      :ok -> :ok
      {:error, %Snap.ResponseError{type: "resource_already_exists_exception"}} -> :ok
      {:error, error} -> raise "could not create #{collection}: #{inspect(error)}"
    end

    clear_collection!(collection)
    on_exit(fn -> clear_collection!(collection) end)
  end

  @doc """
  Writes the named fixture PDF through the configured storage adapter
  (`stage_book_storage!/1` must have run) under a key unique to this call,
  and returns that key, ready for `Cake.Books.Pipeline.ingest/4`.
  """
  @spec stage_fixture!(Cake.PdfFixtures.name()) :: Adapters.key()
  def stage_fixture!(name) do
    key = Adapters.build_key("books", "#{name}_#{System.unique_integer([:positive])}.pdf")
    :ok = Adapters.adapter().write(key, Cake.PdfFixtures.fixture_binary(name))
    key
  end

  @doc "The embedding model the ingestion LiveViews use: `:default_embedding_model` from config."
  @spec embedding_model() :: String.t()
  def embedding_model, do: Application.fetch_env!(:cake, :default_embedding_model)

  @doc """
  The unit vector on the axis `text` hashes to, in the configured embedding
  dimension. Same text, same vector, every run; two different texts land
  on different axes unless their hashes collide.
  """
  @spec deterministic_embedding(String.t()) :: [float()]
  def deterministic_embedding(text) when is_binary(text) do
    dimension = Application.get_env(:cake, :default_embedding_dimension, 1536)
    SearchIntegrationCase.unit_vector(:erlang.phash2(text, dimension))
  end

  @doc """
  The exact string the pipelines embed for a record: the chunk's section
  title or the document's title, a blank line, then the text.
  """
  @spec embed_input(Chunk.t() | ParsedDocument.t()) :: String.t()
  def embed_input(%Chunk{section_title: section_title, text: text}),
    do: "#{section_title}\n\n#{text}"

  def embed_input(%ParsedDocument{title: title, text: text}), do: "#{title}\n\n#{text}"

  @doc """
  Stubs `Cake.Embeddings.Mock.embed/3` for the test: every call answers
  `on_input.(params.input)` — a vector, wrapped in the provider's success
  shape (a usage map, the `:struct` passthrough, `attrs.embedding`), or an
  `{:error, message}` passed through as the provider's failure. Defaults to
  `deterministic_embedding/1`. The stub runs in the pipelines' task
  processes, which Mox allows through `$callers`.
  """
  @spec stub_embeddings((String.t() -> embedding_response())) :: :ok
  def stub_embeddings(on_input \\ &deterministic_embedding/1) when is_function(on_input, 1) do
    Mox.stub(Cake.Embeddings.Mock, :embed, fn _service, %{input: input} = params, _model ->
      case on_input.(input) do
        {:error, message} ->
          {:error, message}

        vector when is_list(vector) ->
          {:ok,
           %{
             usage: %{"prompt_tokens" => 1, "total_tokens" => 1},
             struct: Map.get(params, :struct),
             attrs: %{embedding: vector}
           }}
      end
    end)

    :ok
  end

  @doc """
  A `stub_embeddings/1` function that answers the *first* call for each
  input in `first_calls` with the response mapped to it, and every other
  call (later calls for those inputs, and all calls for any other input)
  with `deterministic_embedding/1`. The bookkeeping lives in an agent
  supervised by the test, so the pipelines' concurrent embedding tasks
  share it.
  """
  @spec once_then_deterministic(%{String.t() => embedding_response()}) ::
          (String.t() -> embedding_response())
  def once_then_deterministic(first_calls) when is_map(first_calls) do
    agent = start_supervised!({Agent, fn -> first_calls end})

    fn input ->
      Agent.get_and_update(agent, fn pending ->
        case Map.pop(pending, input) do
          {nil, pending} -> {deterministic_embedding(input), pending}
          {response, rest} -> {response, rest}
        end
      end)
    end
  end

  @doc """
  Every document id in the GDS's fixed collection on the real node, after a
  refresh, in no particular order.
  """
  @spec indexed_ids!(module()) :: [String.t()]
  def indexed_ids!(gds) when is_atom(gds) do
    collection = gds.collection_name()
    SearchIntegrationCase.refresh!(collection)

    case OpenSearch.search(Cake.Search.Query.new(collection, size: @max_result_window)) do
      {:ok, hits} -> Enum.map(hits, & &1.id)
      {:error, error} -> raise "could not list #{collection}: #{inspect(error)}"
    end
  end

  @doc "The book's chunks from Postgres in `chunk_index` order."
  @spec chunks_in_order(ParsedBook.t()) :: [Chunk.t()]
  def chunks_in_order(%ParsedBook{id: book_id}) do
    Repo.all(from c in Chunk, where: c.parsed_book_id == ^book_id, order_by: c.chunk_index)
  end

  @doc """
  Deletes every document in `collection` and refreshes it, so the next
  search sees an empty collection. Raises on any cluster error.
  """
  @spec clear_collection!(String.t()) :: :ok
  def clear_collection!(collection) when is_binary(collection) do
    # delete_by_query only sees what a search sees: without the refresh a
    # document indexed moments ago (the mapping refreshes every 30s) would
    # survive the clear and surface in a later test.
    SearchIntegrationCase.refresh!(collection)
    query = %{query: %{match_all: %{}}}

    case Snap.Search.delete_by_query(Deployment, collection, query, refresh: true) do
      {:ok, %Snap.DeleteResponse{failures: [], version_conflicts: 0}} ->
        :ok

      {:ok, %Snap.DeleteResponse{} = response} ->
        raise "clearing #{collection} left documents behind: #{inspect(response)}"

      {:error, error} ->
        raise "could not clear #{collection}: #{inspect(error)}"
    end
  end

  defp mapping_schema_for!(gds) do
    case List.keyfind(Deployment.collections(), gds, 0) do
      {^gds, mapping_schema} ->
        mapping_schema

      nil ->
        raise ArgumentError,
              "#{inspect(gds)} is not in the :search_collections config: #{inspect(Deployment.collections())}"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:cake, key)
  defp restore_env(key, value), do: Application.put_env(:cake, key, value)
end
