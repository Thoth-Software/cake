defmodule Cake.Citations do
  @moduledoc """
  Parses `[N]` markers from LLM response text and resolves them against a
  chunk_map built from `Cake.Citable` metadata.
  """

  require Logger

  @citation_pattern ~r/\[(\d+)\]/

  @type citation :: %{
          required(:index) => pos_integer(),
          required(:metadata) => Cake.Citable.metadata()
        }

  @doc """
  Extract citations from response text using the provided chunk_map.

  The chunk_map's values are `Cake.Citable.metadata()` maps, not Books-
  specific shapes. Returns a tuple:

    * first element: ordered (by first appearance in text), deduplicated
      list of valid citations, each carrying its original index and its
      metadata.
    * second element: list of indices that appeared in the text but were
      not present in the chunk_map (i.e., hallucinated by the LLM).

  Hallucinated indices are also logged at warn level for operational
  visibility, but the returned list is what callers should use to surface
  warnings to end users.
  """
  @spec extract(String.t(), map()) :: {[citation()], [pos_integer()]}
  def extract(response_text, chunk_map) do
    all_indices =
      @citation_pattern
      |> Regex.scan(response_text)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
      |> Enum.uniq()

    {valid_rev, hallucinated_rev} =
      Enum.reduce(all_indices, {[], []}, fn idx, {valid, halluc} ->
        case Map.fetch(chunk_map, idx) do
          {:ok, metadata} -> {[%{index: idx, metadata: metadata} | valid], halluc}
          :error -> {valid, [idx | halluc]}
        end
      end)

    hallucinated = Enum.reverse(hallucinated_rev)

    Enum.each(hallucinated, fn idx ->
      Logger.warning("Citation [#{idx}] not found in chunk_map, marking as hallucinated")
    end)

    {Enum.reverse(valid_rev), hallucinated}
  end
end
