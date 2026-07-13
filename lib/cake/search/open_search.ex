defmodule Cake.Search.OpenSearch do
  @moduledoc """
  OpenSearch implementation of the `Cake.Search` behaviour.

  Builds queries via `Cake.Search.Query` and executes them against the
  configured search backend. Owns retrieval and chunk expansion. Does not own
  munging — that's `Prompt`'s province.

  Retrieval is parameterized on a `Cake.GDS` module passed via the `:gds` opt.
  The GDS module supplies the target collection (`collection_name/0`), default
  search fields (`search_fields/0`), hit hydration (`load_from_hits/1`), and
  optional neighbor expansion (`expand_with_neighbors/2`). This module is
  GDS-agnostic — adding a new GDS does not require changes here.
  """

  @behaviour Cake.Search

  alias Cake.Search.Backend
  alias Cake.Search.Hit
  alias Cake.Search.Provenance
  alias Cake.Search.Query
  alias Cake.Search.Result

  @default_size 30
  @default_k 30
  @default_ef_search 256
  @default_keyword_weight 0.8

  @spec default_size() :: pos_integer()
  def default_size, do: @default_size

  @spec default_k() :: pos_integer()
  def default_k, do: @default_k

  @spec default_ef_search() :: pos_integer()
  def default_ef_search, do: @default_ef_search

  @spec default_keyword_weight() :: float()
  def default_keyword_weight, do: @default_keyword_weight

  @impl Cake.Search
  @spec search(Query.t()) :: {:ok, [Hit.t()]} | {:error, any()}
  def search(%Query{} = query) do
    Backend.backend().search(query)
  end

  @doc """
  Run a keyword/vector/hybrid search against the GDS's collection.

  Required opt: `:gds` — a module implementing `Cake.GDS`. Other opts:
  `:size`, `:k`, `:keyword_weight`, `:fields`. `embedding` may be
  nil for keyword-only search.
  """
  @impl Cake.Search
  @spec search_chunks(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, [Hit.t()]} | {:error, any()}
  def search_chunks(search_type, keywords, embedding \\ nil, opts \\ []) do
    gds = Keyword.fetch!(opts, :gds)
    collection = gds.collection_name()
    query = build_query(search_type, collection, keywords, embedding, opts, gds.search_fields())
    Backend.backend().search(query)
  end

  @doc """
  Search the GDS's collection, then expand each hit by fetching neighboring
  records via `gds.expand_with_neighbors/2`. Returns a list of
  `Cake.Search.Result.t()` structs. Direct hits carry `hit_source: :search`
  and the backend `_score`; expanded neighbors carry `hit_source: :expansion`
  and `backend_score: nil`.

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
        ) :: {:ok, [Result.t()]} | {:error, any()}
  def search_chunks_with_context(
        search_type,
        keywords,
        embedding \\ nil,
        expand \\ Cake.Search.default_expand_offset(),
        opts \\ []
      ) do
    gds = Keyword.fetch!(opts, :gds)
    provenance = %Provenance{search_type: search_type, query_text: keywords}

    with {:ok, hits} <- search_chunks(search_type, keywords, embedding, opts) do
      {:ok, build_results(hits, gds, gds.collection_name(), provenance, expand)}
    end
  end

  @spec build_results(
          [Hit.t()],
          module(),
          String.t(),
          Provenance.t(),
          non_neg_integer()
        ) :: [Result.t()]
  defp build_results(hits, gds, collection, provenance, expand) do
    scores_by_id = Map.new(hits, fn hit -> {hit.id, hit.score} end)
    units = gds.load_from_hits(hits)
    original_ids = MapSet.new(units, & &1.id)
    all_expanded = gds.expand_with_neighbors(units, expand)

    Enum.map(all_expanded, fn unit ->
      if MapSet.member?(original_ids, unit.id) do
        Result.new_from_search(unit, Map.get(scores_by_id, unit.id), collection, provenance)
      else
        Result.new_from_expansion(unit, collection, provenance)
      end
    end)
  end

  @impl Cake.Search
  @spec search_docs(:keyword | :vector | :hybrid, String.t(), [float()] | nil, keyword()) ::
          {:ok, [Hit.t()]} | {:error, any()}
  def search_docs(search_type, keywords, embedding \\ nil, opts \\ []) do
    gds = Keyword.fetch!(opts, :gds)
    collection = gds.collection_name()
    query = build_query(search_type, collection, keywords, embedding, opts, gds.search_fields())
    Backend.backend().search(query)
  end

  defp build_query(:keyword, collection, keywords, _embedding, opts, default_fields) do
    fields = Keyword.get(opts, :fields, default_fields)
    size = Keyword.get(opts, :size, @default_size)
    Query.match(Query.new(collection, size: size), keywords, fields)
  end

  defp build_query(:vector, collection, _keywords, embedding, opts, _default_fields) do
    k = Keyword.get(opts, :k, @default_k)
    size = Keyword.get(opts, :size, @default_size)
    ef_search = Keyword.get(opts, :ef_search, @default_ef_search)

    collection
    |> Query.new(size: size)
    |> Query.knn("embedding", embedding, k, ef_search: ef_search)
  end

  defp build_query(:hybrid, collection, keywords, embedding, opts, default_fields) do
    fields = Keyword.get(opts, :fields, default_fields)
    size = Keyword.get(opts, :size, @default_size)
    k = Keyword.get(opts, :k, @default_k)
    ef_search = Keyword.get(opts, :ef_search, @default_ef_search)
    keyword_weight = Keyword.get(opts, :keyword_weight, @default_keyword_weight)
    base = Query.new(collection, size: size)

    base
    |> Query.knn("embedding", embedding, k, ef_search: ef_search)
    |> Query.match(keywords, fields, boost: keyword_weight)
  end
end
