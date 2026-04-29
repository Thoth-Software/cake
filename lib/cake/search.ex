defmodule Cake.Search do
  @moduledoc """
  Defines the search behaviour contract and provides shared scoring utilities.

  ## Behaviour contract

  The real implementation is `Cake.Search.OpenSearch`. In tests: `Cake.Search.Mock` (Mox).

  Callers receive the implementation module as an injected argument, following the same
  pattern as `cluster` injection into `Conversation`.

  ## Scoring utilities

  `cosine_similarity/2`, `score_results/2`, `normalize_and_combine/1`,
  `filter_by_threshold/2`, `sort_by_relevance/1`, and `unzip_results/1` are pure
  functions available to any caller, regardless of which search implementation is in use.
  The boundary test: if it needs a network call or a database query, it belongs in the
  implementation module. If it's math on data already in memory, it belongs here.
  """

  alias Cake.Search.Result

  @type search_type :: :keyword | :vector | :hybrid
  @type search_opts :: keyword()
  @type search_result :: {:ok, Snap.SearchResponse.t()} | {:error, any()}
  @type result_list :: [Result.t()]

  @doc "Execute an arbitrary `%Cake.Search.Query{}` against the cluster."
  @callback search(Cake.Search.Query.t()) :: search_result()

  @doc """
  Search for retrieval units (chunks, documents — determined by the GDS
  passed via `opts[:gds]`). Returns raw OpenSearch hits. `embedding` may be
  nil for keyword-only search.
  """
  @callback search_chunks(search_type(), String.t(), [float()] | nil, search_opts()) ::
              search_result()

  @doc """
  Search for retrieval units and expand results with neighboring units (where
  the GDS supports ordering) from Postgres. Returns a list of
  `Cake.Search.Result.t()` structs. `expand` is the neighbor offset.
  Expanded neighbors carry `hit_source: :expansion` and `backend_score: nil`.
  """
  @callback search_chunks_with_context(
              search_type(),
              String.t(),
              [float()] | nil,
              non_neg_integer(),
              search_opts()
            ) ::
              {:ok, result_list()}
              | {:error, any()}

  @doc "Alias of `search_chunks/4` retained for call-site clarity. Same signature."
  @callback search_docs(search_type(), String.t(), [float()] | nil, search_opts()) ::
              search_result()

  # --- Scoring utilities ---
  #
  # These are pure functions for post-retrieval scoring, normalization, and
  # filtering. They are backend-agnostic: any Search implementation's callers
  # can use them. The boundary test: if it needs a network call or a database
  # query, it belongs in the implementation module. If it's math on data
  # already in memory, it belongs here.

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
  def score_results(results, query_embedding) do
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
  def normalize_and_combine(results) do
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

  defp backend_score_bounds(results) do
    scores =
      results
      |> Enum.map(& &1.backend_score)
      |> Enum.reject(&is_nil/1)

    {Enum.min(scores, fn -> 0.0 end), Enum.max(scores, fn -> 0.0 end)}
  end

  defp normalize(value, min, max) when max > min, do: (value - min) / (max - min)
  defp normalize(_value, _min, _max), do: 1.0

  @doc """
  Removes results whose relevance_score is below the given threshold.
  """
  @spec filter_by_threshold([Result.t()], float()) :: [Result.t()]
  def filter_by_threshold(results, threshold) do
    Enum.filter(results, fn %Result{relevance_score: score} -> score >= threshold end)
  end

  @doc """
  Sorts results by relevance_score descending.
  """
  @spec sort_by_relevance([Result.t()]) :: [Result.t()]
  def sort_by_relevance(results) do
    Enum.sort_by(results, & &1.relevance_score, :desc)
  end

  @doc """
  Strips Result wrappers, returning plain retrieval units. Use this at the
  boundary between Search-layer concerns and Generation-layer concerns
  (i.e., in Conversation, before handing units to Prompt/Responses).
  """
  @spec unzip_results([Result.t()]) :: [struct()]
  def unzip_results(results) do
    Enum.map(results, & &1.retrieval_unit)
  end
end
