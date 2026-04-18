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

  @doc "Execute an arbitrary `%Query{}`. Escape hatch for callers that need full query control."
  @impl Cake.Search
  @spec search(Query.t()) :: {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search(%Query{} = query) do
    cluster = query.cluster || @default_cluster
    Snap.Search.search(cluster, query.index, Query.to_opensearch(query))
  end

  @doc """
  Search the chunks_of_books index.

  Options: `:size`, `:k`, `:ef_search`, `:keyword_weight`, `:fields`, `:cluster`.
  `embedding` may be nil for keyword-only search.
  """
  @impl Cake.Search
  @spec search_chunks(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search_chunks(search_type, keywords, embedding \\ nil, opts \\ []) do
    search(
      Query.build(search_type, @chunks_index, %{
        keywords: keywords,
        embedding: embedding,
        fields: Keyword.get(opts, :fields, @chunk_fields),
        size: Keyword.get(opts, :size, @default_size),
        k: Keyword.get(opts, :k, @default_k),
        ef_search: Keyword.get(opts, :ef_search, @default_ef_search),
        keyword_weight: Keyword.get(opts, :keyword_weight, @default_keyword_weight),
        cluster: Keyword.get(opts, :cluster, @default_cluster)
      })
    )
  end

  @doc """
  Search the chunks_of_books index, then expand each hit by fetching neighboring
  chunks from Postgres. Returns `[%Chunk{}]` with `:parsed_book` preloaded.

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
        ) :: {:ok, [Cake.Books.Chunk.t()]} | {:error, any()}
  def search_chunks_with_context(
        search_type,
        keywords,
        embedding \\ nil,
        expand \\ @default_expand_offset,
        opts \\ []
      ) do
    with {:ok, %{hits: hits}} <- search_chunks(search_type, keywords, embedding, opts) do
      {:ok, hits |> Books.chunks_for_hits() |> Books.expand_with_neighbors(expand)}
    end
  end

  @doc "Search the docs index. Same option shape as `search_chunks/4`."
  @impl Cake.Search
  @spec search_docs(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search_docs(search_type, keywords, embedding \\ nil, opts \\ []) do
    search(
      Query.build(search_type, @docs_index, %{
        keywords: keywords,
        embedding: embedding,
        fields: Keyword.get(opts, :fields, @doc_fields),
        size: Keyword.get(opts, :size, @default_size),
        k: Keyword.get(opts, :k, @default_k),
        ef_search: Keyword.get(opts, :ef_search, @default_ef_search),
        keyword_weight: Keyword.get(opts, :keyword_weight, @default_keyword_weight),
        cluster: Keyword.get(opts, :cluster, @default_cluster)
      })
    )
  end
end
