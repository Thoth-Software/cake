defmodule Cake.Responses do
  @moduledoc """
  Post-generation processing for the conversation layer.

  `process/3` runs a six-stage pipeline over a `Result` struct:
  resolve → renumber → rewrite → media → actions → format.
  Each stage is a pure `Result -> Result` transformation.

  A citation stands for a retrieval unit, not for a marker. Resolve keeps one
  citation per `Cake.Citable` `:id`, so a unit that sits at two prompt indices
  is cited once, under the index whose marker appears first. Renumber numbers
  the citations `1..K` in that order, and rewrite shows every marker as the
  number of its unit's citation, so two markers for one unit read the same.
  A hallucinated marker takes no number: it is removed and reported in
  `warnings`.

  LLM transport lives in `Cake.Generation` — this module does no HTTP
  and knows nothing about providers.
  """

  @behaviour Cake.Responses.Behaviour

  use Boundary, top_level?: true, deps: [Cake, Cake.Search], exports: [Result]

  alias Cake.Citable
  alias Cake.Citations
  alias Cake.Responses.Result

  @impl Cake.Responses.Behaviour
  @spec process(String.t(), Cake.Responses.Behaviour.indexed_chunks(), keyword()) :: Result.t()
  def process(raw_text, indexed_chunks, opts \\ []) do
    chunk_map = build_citation_map(indexed_chunks)

    %Result{raw_text: raw_text, chunk_map: chunk_map}
    |> resolve_citations()
    |> renumber_citations()
    |> rewrite_text()
    |> select_media(opts)
    |> extract_actions(opts)
    |> finalize_formatting(opts)
  end

  @doc """
  Builds the chunk map: prompt index → `Cake.Citable.metadata/1` of that
  chunk's retrieval unit. Stage one of `process/3`, and the map
  `Cake.Citations.extract/2` resolves `[N]` markers against.
  """
  @spec build_citation_map(Cake.Responses.Behaviour.indexed_chunks()) :: map()
  def build_citation_map(indexed_chunks) do
    Map.new(indexed_chunks, fn {idx, %Cake.Search.Result{retrieval_unit: unit}} ->
      {idx, Citable.metadata(unit)}
    end)
  end

  # --- Stage 1: resolve ---
  defp resolve_citations(%Result{raw_text: text, chunk_map: map} = result) do
    {parsed, hallucinated} = Citations.extract(text, map)

    citations =
      parsed
      |> Enum.uniq_by(fn %{metadata: m} -> m.id end)
      |> Enum.map(fn %{index: idx, metadata: m} ->
        %{
          old_index: idx,
          new_index: idx,
          id: m.id,
          label: m.label,
          preview: m.preview,
          source_ref: m.source_ref,
          extras: m.extras
        }
      end)

    warnings = Enum.map(hallucinated, &{:hallucinated_citation, &1})

    %{result | citations: citations, warnings: warnings ++ result.warnings}
  end

  # --- Stage 2: renumber ---
  # Resolve leaves the citations in first-appearance order, so a citation's
  # new index is its position. Hallucinated markers are not in the list and
  # take no number.
  defp renumber_citations(%Result{citations: citations} = result) do
    renumbered =
      citations
      |> Enum.with_index(1)
      |> Enum.map(fn {citation, position} -> %{citation | new_index: position} end)

    %{result | citations: renumbered}
  end

  # --- Stage 3: rewrite text ---
  # A marker shows the new index of the citation for the unit at its prompt
  # index, found by `:id`: the unit may be cited under another index.
  defp rewrite_text(%Result{raw_text: text, chunk_map: map, citations: citations} = result) do
    new_index_by_id = Map.new(citations, fn c -> {c.id, c.new_index} end)

    final =
      ~r/\[(\d+)\]/
      |> Regex.replace(text, fn _whole, n_str ->
        case Map.fetch(map, String.to_integer(n_str)) do
          {:ok, %{id: id}} -> "[#{Map.fetch!(new_index_by_id, id)}]"
          :error -> ""
        end
      end)
      |> String.replace(~r/ +/, " ")

    %{result | final_text: final}
  end

  # --- Stage 4: media stub ---
  defp select_media(%Result{} = result, _opts), do: result

  # --- Stage 5: actions ---
  defp extract_actions(%Result{citations: citations} = result, _opts) do
    downloads =
      citations
      |> Enum.reject(&is_nil(&1.source_ref))
      |> Enum.uniq_by(& &1.source_ref)
      |> Enum.map(fn c ->
        %{kind: :download, label: c.label, source_ref: c.source_ref}
      end)

    %{result | actions: downloads}
  end

  # --- Stage 6: format ---
  defp finalize_formatting(%Result{final_text: text} = result, _opts) do
    cleaned =
      text
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    %{result | final_text: cleaned}
  end
end
