defmodule Cake.Search.OpenSearch do
  @moduledoc """
  OpenSearch implementation of the `Cake.Search` behaviour.

  Builds queries via `Cake.Search.Query` and executes them against the cluster
  via `Snap.Search.search/3`. Owns retrieval and chunk expansion. Does not own
  munging — that's `Prompt`'s province.
  """

  @behaviour Cake.Search

  alias Cake.Books
  alias Cake.Search.Query

  # TODO make these defaults into config vars
  @default_size 30
  @default_k 30
  @default_ef_search 256
  @default_keyword_weight 0.8
  @default_cluster Cake.Documents.Cluster
  @default_expand_offset 2

  @chunks_index "chunks_of_books"
  @docs_index "docs"

  @chunk_fields ["section_title^2", "text"]
  @doc_fields ["title^3", "text"]

  @spec default_size() :: pos_integer()
  def default_size, do: @default_size

  @spec default_k() :: pos_integer()
  def default_k, do: @default_k

  @spec default_ef_search() :: pos_integer()
  def default_ef_search, do: @default_ef_search

  @spec default_keyword_weight() :: float()
  def default_keyword_weight, do: @default_keyword_weight

  @spec default_expand_offset() :: non_neg_integer()
  def default_expand_offset, do: @default_expand_offset

  @spec chunk_fields() :: [String.t()]
  def chunk_fields, do: @chunk_fields

  @spec doc_fields() :: [String.t()]
  def doc_fields, do: @doc_fields

  @doc "Execute an arbitrary `%Query{}` against the default cluster."
  @impl Cake.Search
  @spec search(Query.t()) :: {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search(%Query{} = query) do
    Snap.Search.search(@default_cluster, query.index, Query.to_query_map(query))
  end

  @doc """
  Search the chunks_of_books index.

  Options: `:size`, `:k`, `:keyword_weight`, `:fields`, `:cluster`.
  `embedding` may be nil for keyword-only search.
  """
  @impl Cake.Search
  @spec search_chunks(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search_chunks(search_type, keywords, embedding \\ nil, opts \\ []) do
    cluster = Keyword.get(opts, :cluster, @default_cluster)
    query = build_query(search_type, @chunks_index, keywords, embedding, opts, @chunk_fields)
    Snap.Search.search(cluster, @chunks_index, Query.to_query_map(query))
  end

  @doc """
  Search the chunks_of_books index, then expand each hit by fetching neighboring
  chunks from Postgres. Returns tagged tuples `{%Chunk{}, %{os_score: float() | nil}}`
  with `:parsed_book` preloaded. Direct hits carry their OpenSearch `_score`; expanded
  neighbors receive `os_score: nil`.

  `expand` is the neighbor offset: how many chunks on each side of a hit to include.
  Accepts all the same opts as `search_chunks/4`.
  """
  @impl Cake.Search
  @spec search_chunks_with_context(
          :keyword | :vector | :hybrid,
          String.t(),
          [float()] | nil,
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, [{Cake.Books.Chunk.t(), %{os_score: float() | nil}}]}
          | {:error, any()}
  def search_chunks_with_context(
        search_type,
        keywords,
        embedding \\ nil,
        expand \\ @default_expand_offset,
        opts \\ []
      ) do
    with {:ok, %{hits: hits}} <- search_chunks(search_type, keywords, embedding, opts) do
      {:ok, hits |> scored_chunks_for_hits() |> scored_expand_with_neighbors(expand)}
    end
  end

  @spec scored_chunks_for_hits(%Snap.Hits{} | [Snap.Hit.t()]) ::
          [{Cake.Books.Chunk.t(), %{os_score: float()}}]
  defp scored_chunks_for_hits(hits) do
    scores_by_id = Map.new(hits, fn hit -> {hit.source["id"], hit.score} end)
    chunks = Books.chunks_for_hits(hits)
    Enum.map(chunks, fn chunk -> {chunk, %{os_score: Map.get(scores_by_id, chunk.id)}} end)
  end

  @spec scored_expand_with_neighbors(
          [{Cake.Books.Chunk.t(), %{os_score: float()}}],
          non_neg_integer()
        ) :: [{Cake.Books.Chunk.t(), %{os_score: float() | nil}}]
  defp scored_expand_with_neighbors(scored_chunks, offset) do
    plain_chunks = Enum.map(scored_chunks, &elem(&1, 0))
    original_ids = MapSet.new(plain_chunks, & &1.id)
    all_expanded = Books.expand_with_neighbors(plain_chunks, offset)
    scores_by_id = Map.new(scored_chunks, fn {chunk, scores} -> {chunk.id, scores} end)

    Enum.map(all_expanded, fn chunk ->
      if MapSet.member?(original_ids, chunk.id) do
        {chunk, Map.get(scores_by_id, chunk.id, %{os_score: nil})}
      else
        {chunk, %{os_score: nil}}
      end
    end)
  end

  @doc "Search the docs index. Same option shape as `search_chunks/4`."
  @impl Cake.Search
  @spec search_docs(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search_docs(search_type, keywords, embedding \\ nil, opts \\ []) do
    cluster = Keyword.get(opts, :cluster, @default_cluster)
    query = build_query(search_type, @docs_index, keywords, embedding, opts, @doc_fields)
    Snap.Search.search(cluster, @docs_index, Query.to_query_map(query))
  end

  defp build_query(:keyword, index, keywords, _embedding, opts, default_fields) do
    fields = Keyword.get(opts, :fields, default_fields)
    size = Keyword.get(opts, :size, @default_size)
    Query.match(Query.new(index, size: size), keywords, fields)
  end

  defp build_query(:vector, index, _keywords, embedding, opts, _default_fields) do
    k = Keyword.get(opts, :k, @default_k)
    size = Keyword.get(opts, :size, @default_size)

    index
    |> Query.new(size: size)
    |> Query.knn("embedding", embedding, k)
  end

  defp build_query(:hybrid, index, keywords, embedding, opts, default_fields) do
    fields = Keyword.get(opts, :fields, default_fields)
    size = Keyword.get(opts, :size, @default_size)
    k = Keyword.get(opts, :k, @default_k)
    keyword_weight = Keyword.get(opts, :keyword_weight, @default_keyword_weight)
    base = Query.new(index, size: size)

    base
    |> Query.knn("embedding", embedding, k)
    |> Query.match(keywords, fields, boost: keyword_weight)
  end
end
