defmodule Cake.Search do
  @moduledoc """
  Cake-internal search orchestration.

  Owns the mapping from search type (`:keyword`, `:vector`, `:hybrid`) to
  `Cake.Search.Query` construction, delegates query execution to the
  configured `Cake.Search.Backend`, and hydrates hits into
  `Cake.Search.Result` structs via the GDS's `load_from_hits/1`.

  ## Scoring utilities

  `cosine_similarity/2`, `score_results/2`, `normalize_and_combine/1`, and
  `sort_by_relevance/1` are pure functions available to any caller.
  The boundary test: if it needs a network call or a database query, it
  belongs in the backend. If it's math on data already in memory, it
  belongs here.
  """

  alias Cake.Search.Backend
  alias Cake.Search.Hit
  alias Cake.Search.Provenance
  alias Cake.Search.Query
  alias Cake.Search.Result

  @type search_type :: :keyword | :vector | :hybrid
  @type search_opts :: keyword()
  @type search_result :: {:ok, [Hit.t()]} | {:error, Backend.search_error()}
  @type result_list :: [Result.t()]

  @default_size 30
  @default_k 30
  @default_ef_search 256
  @default_keyword_weight 0.8
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

  @doc """
  Run a keyword/vector/hybrid search against the GDS's collection.

  Required opt: `:gds` — a module implementing `Cake.GDS`. Other opts:
  `:size`, `:k`, `:keyword_weight`, `:fields`. `embedding` may be
  nil for keyword-only search.
  """
  @spec search_chunks(search_type(), String.t(), [float()] | nil, search_opts()) ::
          search_result()
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
  @spec search_chunks_with_context(
          search_type(),
          String.t(),
          [float()] | nil,
          non_neg_integer(),
          search_opts()
        ) :: {:ok, result_list()} | {:error, Backend.search_error()}
  def search_chunks_with_context(
        search_type,
        keywords,
        embedding \\ nil,
        expand \\ @default_expand_offset,
        opts \\ []
      ) do
    gds = Keyword.fetch!(opts, :gds)
    provenance = %Provenance{search_type: search_type, query_text: keywords}

    with {:ok, hits} <- search_chunks(search_type, keywords, embedding, opts) do
      {:ok, build_results(hits, gds, gds.collection_name(), provenance, expand)}
    end
  end

  @doc "Alias of `search_chunks/4` retained for call-site clarity. Same signature."
  @spec search_docs(search_type(), String.t(), [float()] | nil, search_opts()) ::
          search_result()
  def search_docs(search_type, keywords, embedding \\ nil, opts \\ []) do
    search_chunks(search_type, keywords, embedding, opts)
  end

  # --- Scoring utilities ---

  @doc """
  Computes cosine similarity between two embedding vectors.
  Returns a float in [-1.0, 1.0]. Returns 0.0 if either vector is
  a zero vector (to avoid division by zero).
  """
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(vec_a, vec_b) do
    {dot, mag_sq_a, mag_sq_b} =
      Enum.zip_reduce(vec_a, vec_b, {0.0, 0.0, 0.0}, fn a, b, {d, msa, msb} ->
        {d + a * b, msa + a * a, msb + b * b}
      end)

    compute_cosine(dot, mag_sq_a, mag_sq_b)
  end

  defp compute_cosine(_dot, mag_a, mag_b) when mag_a == 0.0 or mag_b == 0.0, do: 0.0
  defp compute_cosine(dot, mag_a, mag_b), do: dot / :math.sqrt(mag_a * mag_b)

  @doc """
  Populates `cosine_score` on each Result by comparing the unit's embedding
  to the query embedding. Units with nil embeddings receive cosine_score: 0.0.
  """
  @spec score_results([Result.t()], [float()]) :: [Result.t()]
  def score_results(results, query_embedding) when is_list(results) do
    Enum.map(results, fn %Result{retrieval_unit: unit} = result ->
      cosine =
        case unit.embedding do
          nil -> 0.0
          embedding -> cosine_similarity(query_embedding, embedding)
        end

      %{result | cosine_score: cosine}
    end)
  end

  @doc """
  Normalizes backend_score and cosine_score across the result set using
  min-max normalization, then computes the final `relevance_score` as a
  weighted average.

  Results without a backend_score (expanded neighbors) use cosine_score
  alone. Results with a backend_score use 0.5 * normalized_backend_score
  + 0.5 * normalized_cosine_score.
  """
  @spec normalize_and_combine([Result.t()]) :: [Result.t()]
  def normalize_and_combine(results) when is_list(results) do
    {os_min, os_max} = backend_score_bounds(results)
    cosine_scores = Enum.map(results, & &1.cosine_score)
    cosine_min = Enum.min(cosine_scores, fn -> 0.0 end)
    cosine_max = Enum.max(cosine_scores, fn -> 0.0 end)

    Enum.map(results, fn %Result{backend_score: bs, cosine_score: cs} = result ->
      norm_cosine = normalize(cs, cosine_min, cosine_max)

      relevance =
        case bs do
          nil -> norm_cosine
          score -> 0.5 * normalize(score, os_min, os_max) + 0.5 * norm_cosine
        end

      %{result | relevance_score: relevance}
    end)
  end

  @doc """
  Sorts results by relevance_score descending.
  """
  @spec sort_by_relevance([Result.t()]) :: [Result.t()]
  def sort_by_relevance(results) when is_list(results) do
    Enum.sort_by(results, & &1.relevance_score, :desc)
  end

  # --- Private ---

  @spec build_results([Hit.t()], module(), String.t(), Provenance.t(), non_neg_integer()) ::
          [Result.t()]
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

  defp backend_score_bounds(results) do
    scores =
      results
      |> Enum.map(& &1.backend_score)
      |> Enum.reject(&is_nil/1)

    {Enum.min(scores, fn -> 0.0 end), Enum.max(scores, fn -> 0.0 end)}
  end

  defp normalize(value, min, max) when max > min, do: (value - min) / (max - min)
  defp normalize(_value, _min, _max), do: 1.0
end
