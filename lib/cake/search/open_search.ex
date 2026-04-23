defmodule Cake.Search.OpenSearch do
  @moduledoc """
  OpenSearch implementation of the `Cake.Search` behaviour.

  Builds queries via `Cake.Search.Query` and executes them against the cluster
  via `Snap.Search.search/3`. Owns retrieval and chunk expansion. Does not own
  munging — that's `Prompt`'s province.

  Retrieval is parameterized on a `Cake.GDS` module passed via the `:gds` opt.
  The GDS module supplies the target index (`index_name/0`), default search
  fields (`search_fields/0`), hit hydration (`load_from_hits/1`), and optional
  neighbor expansion (`expand_with_neighbors/2`). OpenSearch is GDS-agnostic —
  adding a new GDS does not require changes here.
  """

  @behaviour Cake.Search

  alias Cake.Search.Query

  # TODO make these defaults into config vars
  @default_size 30
  @default_k 30
  @default_ef_search 256
  @default_keyword_weight 0.8
  @default_cluster Cake.Documents.Cluster
  @default_expand_offset 2

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

  @doc "Execute an arbitrary `%Query{}` against the default cluster."
  @impl Cake.Search
  @spec search(Query.t()) :: {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search(%Query{} = query) do
    Snap.Search.search(@default_cluster, query.index, Query.to_query_map(query))
  end

  @doc """
  Run a keyword/vector/hybrid search against the GDS's index.

  Required opt: `:gds` — a module implementing `Cake.GDS`. Other opts:
  `:size`, `:k`, `:keyword_weight`, `:fields`, `:cluster`. `embedding` may be
  nil for keyword-only search.
  """
  @impl Cake.Search
  @spec search_chunks(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search_chunks(search_type, keywords, embedding \\ nil, opts \\ []) do
    gds = Keyword.fetch!(opts, :gds)
    cluster = Keyword.get(opts, :cluster, @default_cluster)
    index = gds.index_name()
    query = build_query(search_type, index, keywords, embedding, opts, gds.search_fields())
    Snap.Search.search(cluster, index, Query.to_query_map(query))
  end

  @doc """
  Search the GDS's index, then expand each hit by fetching neighboring records
  via `gds.expand_with_neighbors/2`. Returns tagged tuples
  `{record, %{os_score: float() | nil}}`. Direct hits carry their OpenSearch
  `_score`; expanded neighbors receive `os_score: nil`.

  `expand` is the neighbor offset. Accepts all the same opts as
  `search_chunks/4`, including the required `:gds` opt.
  """
  @impl Cake.Search
  @spec search_chunks_with_context(
          :keyword | :vector | :hybrid,
          String.t(),
          [float()] | nil,
          non_neg_integer(),
          keyword()
        ) :: {:ok, [{struct(), %{os_score: float() | nil}}]} | {:error, any()}
  def search_chunks_with_context(
        search_type,
        keywords,
        embedding \\ nil,
        expand \\ @default_expand_offset,
        opts \\ []
      ) do
    gds = Keyword.fetch!(opts, :gds)

    with {:ok, %{hits: hits}} <- search_chunks(search_type, keywords, embedding, opts) do
      {:ok, hits |> scored_units_for_hits(gds) |> scored_expand_with_neighbors(gds, expand)}
    end
  end

  @spec scored_units_for_hits(%Snap.Hits{} | [Snap.Hit.t()], module()) ::
          [{struct(), %{os_score: float()}}]
  defp scored_units_for_hits(hits, gds) do
    scores_by_id = Map.new(hits, fn hit -> {hit.source["id"], hit.score} end)
    units = gds.load_from_hits(hits)
    Enum.map(units, fn unit -> {unit, %{os_score: Map.get(scores_by_id, unit.id)}} end)
  end

  @spec scored_expand_with_neighbors(
          [{struct(), %{os_score: float()}}],
          module(),
          non_neg_integer()
        ) :: [{struct(), %{os_score: float() | nil}}]
  defp scored_expand_with_neighbors(scored_units, gds, offset) do
    plain_units = Enum.map(scored_units, &elem(&1, 0))
    original_ids = MapSet.new(plain_units, & &1.id)
    all_expanded = gds.expand_with_neighbors(plain_units, offset)
    scores_by_id = Map.new(scored_units, fn {unit, scores} -> {unit.id, scores} end)

    Enum.map(all_expanded, fn unit ->
      if MapSet.member?(original_ids, unit.id) do
        {unit, Map.get(scores_by_id, unit.id, %{os_score: nil})}
      else
        {unit, %{os_score: nil}}
      end
    end)
  end

  @doc "Search the GDS's index. Same option shape as `search_chunks/4`."
  @impl Cake.Search
  @spec search_docs(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, Snap.SearchResponse.t()} | {:error, any()}
  def search_docs(search_type, keywords, embedding \\ nil, opts \\ []) do
    gds = Keyword.fetch!(opts, :gds)
    cluster = Keyword.get(opts, :cluster, @default_cluster)
    index = gds.index_name()
    query = build_query(search_type, index, keywords, embedding, opts, gds.search_fields())
    Snap.Search.search(cluster, index, Query.to_query_map(query))
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
