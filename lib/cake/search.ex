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

  @type search_type :: :keyword | :vector | :hybrid
  @type search_opts :: keyword()
  @type search_result :: {:ok, Snap.SearchResponse.t()} | {:error, any()}

  @typedoc "A chunk paired with its per-query relevance scores."
  @type scored_result :: {Cake.Books.Chunk.t(), scores_map()}

  @typedoc """
  Per-query scoring metadata for a chunk.
  - os_score: OpenSearch's fused hybrid _score. nil for expanded neighbors.
  - cosine_score: Cosine similarity between query embedding and chunk embedding.
  - relevance_score: Weighted composite of available signals.
  """
  @type scores_map :: %{
          os_score: float() | nil,
          cosine_score: float(),
          relevance_score: float()
        }

  @doc "Execute an arbitrary `%Cake.Search.Query{}` against the cluster."
  @callback search(Cake.Search.Query.t()) :: search_result()

  @doc """
  Search for book chunks. Returns raw OpenSearch hits.
  `embedding` may be nil for keyword-only search.
  """
  @callback search_chunks(search_type(), String.t(), [float()] | nil, search_opts()) ::
              search_result()

  @doc """
  Search for book chunks and expand results with neighboring chunks from Postgres.
  Returns tagged tuples `{%Cake.Books.Chunk{}, %{os_score: float() | nil}}` with
  `:parsed_book` preloaded. `expand` is the neighbor offset (e.g. 2 means fetch
  2 chunks on each side of every hit). Expanded neighbors receive `os_score: nil`.
  """
  @callback search_chunks_with_context(
              search_type(),
              String.t(),
              [float()] | nil,
              non_neg_integer(),
              search_opts()
            ) ::
              {:ok, [{Cake.Books.Chunk.t(), %{os_score: float() | nil}}]}
              | {:error, any()}

  @doc "Search for parsed documents (programming docs). Same signature shape as `search_chunks/4`."
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
  Attaches cosine similarity scores to a list of scored results.
  Expects each result to already have :os_score populated (or nil for expanded neighbors).
  Computes :cosine_score from the chunk's embedding and the query embedding.
  Sets :relevance_score to 0.0 as a placeholder; call `normalize_and_combine/1` to
  compute final relevance scores.

  Chunks with nil embeddings receive cosine_score: 0.0.
  """
  @spec score_results([{Cake.Books.Chunk.t(), %{os_score: float() | nil}}], [float()]) ::
          [scored_result()]
  def score_results(results, query_embedding) do
    Enum.map(results, fn {chunk, scores} ->
      cosine_score =
        case chunk.embedding do
          nil -> 0.0
          embedding -> cosine_similarity(query_embedding, embedding)
        end

      {chunk, Map.merge(scores, %{cosine_score: cosine_score, relevance_score: 0.0})}
    end)
  end

  @doc """
  Normalizes os_score and cosine_score across the result set using min-max
  normalization, then computes the final relevance_score as a weighted average.

  Results without os_score (expanded neighbors) use cosine_score alone.
  Results with os_score use 0.5 * normalized_os_score + 0.5 * normalized_cosine_score.

  Returns the list with updated scores maps.
  """
  @spec normalize_and_combine([scored_result()]) :: [scored_result()]
  def normalize_and_combine(results) do
    {os_min, os_max} = os_score_bounds(results)
    cosine_scores = Enum.map(results, fn {_, %{cosine_score: s}} -> s end)
    cosine_min = Enum.min(cosine_scores, fn -> 0.0 end)
    cosine_max = Enum.max(cosine_scores, fn -> 0.0 end)

    Enum.map(results, fn {chunk, %{os_score: os_score, cosine_score: cosine_score} = scores} ->
      norm_cosine = normalize(cosine_score, cosine_min, cosine_max)

      relevance_score =
        case os_score do
          nil -> norm_cosine
          score -> 0.5 * normalize(score, os_min, os_max) + 0.5 * norm_cosine
        end

      {chunk, %{scores | relevance_score: relevance_score}}
    end)
  end

  defp os_score_bounds(results) do
    os_scores =
      results
      |> Enum.map(fn {_, %{os_score: s}} -> s end)
      |> Enum.reject(&is_nil/1)

    {Enum.min(os_scores, fn -> 0.0 end), Enum.max(os_scores, fn -> 0.0 end)}
  end

  defp normalize(value, min, max) when max > min, do: (value - min) / (max - min)
  defp normalize(_value, _min, _max), do: 1.0

  @doc """
  Removes results whose relevance_score is below the given threshold.
  """
  @spec filter_by_threshold([scored_result()], float()) :: [scored_result()]
  def filter_by_threshold(results, threshold) do
    Enum.filter(results, fn {_chunk, %{relevance_score: score}} -> score >= threshold end)
  end

  @doc """
  Sorts results by relevance_score descending.
  """
  @spec sort_by_relevance([scored_result()]) :: [scored_result()]
  def sort_by_relevance(results) do
    Enum.sort_by(results, fn {_chunk, %{relevance_score: score}} -> score end, :desc)
  end

  @doc """
  Strips scores, returning plain chunks. Use this at the boundary between
  Search-layer concerns and Generation-layer concerns (i.e., in Conversation,
  before handing chunks to Prompt/Responses).
  """
  @spec unzip_results([scored_result()]) :: [Cake.Books.Chunk.t()]
  def unzip_results(results) do
    Enum.map(results, &elem(&1, 0))
  end
end
