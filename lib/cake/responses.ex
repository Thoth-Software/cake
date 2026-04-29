defmodule Cake.Responses do
  @moduledoc """
  Post-generation processing for the conversation layer.

  `process/3` runs a six-stage pipeline over a `Result` struct:
  resolve → renumber → rewrite → media → actions → format.
  Each stage is a pure `Result -> Result` transformation.

  LLM transport lives in `Cake.Generation` — this module does no HTTP
  and knows nothing about providers.
  """

  @behaviour Cake.Responses.Behaviour

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
      Enum.map(parsed, fn %{index: idx, metadata: m} ->
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
  defp renumber_citations(%Result{raw_text: text, citations: citations} = result) do
    first_appearances =
      ~r/\[(\d+)\]/
      |> Regex.scan(text)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
      |> Enum.uniq()

    renumbered =
      citations
      |> Enum.map(fn c ->
        case Enum.find_index(first_appearances, &(&1 == c.old_index)) do
          nil -> c
          i -> %{c | new_index: i + 1}
        end
      end)
      |> Enum.sort_by(& &1.new_index)

    %{result | citations: renumbered}
  end

  # --- Stage 3: rewrite text ---
  defp rewrite_text(%Result{raw_text: text, citations: citations} = result) do
    lookup = Map.new(citations, fn c -> {c.old_index, c.new_index} end)

    final =
      ~r/\[(\d+)\]/
      |> Regex.replace(text, fn _whole, n_str ->
        old = String.to_integer(n_str)

        case Map.fetch(lookup, old) do
          {:ok, new} -> "[#{new}]"
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
