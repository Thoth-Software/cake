# User-owned LawSpec adapter for laws/responses.lawspec.
defmodule Cake.Laws.Responses do
  @moduledoc """
  Adapts `Cake.Responses.process/3` and `build_citation_map/1` to the
  `cake.laws.responses` unit.

  Each generated chunk becomes what `Cake.Prompt` hands `Responses`: a prompt
  index and a `Cake.Search.Result` whose retrieval unit is a
  `Cake.Laws.FakeUnit` carrying the chunk's metadata. The `Result` struct
  comes back as a record the laws can compare.

  The translation is strict on purpose, so a shape the specification does
  not name fails the law instead of passing through: a warning that is not
  `{:hallucinated_citation, n}`, an action kind other than `:download` or
  `:external_link`, or a citation `:id` that is not text has no clause here.

  `process/3` logs a warning per hallucinated index, through
  `Cake.Citations`; `Cake.Laws.Quiet` keeps that out of the test output.
  """

  alias Cake.Laws.FakeUnit
  alias Cake.Laws.Quiet
  alias Cake.Responses
  alias Cake.Responses.Result
  alias Cake.Search.Provenance
  alias LawSpec.Data.Action
  alias LawSpec.Data.Cited
  alias LawSpec.Data.IndexedChunk
  alias LawSpec.Data.KeyVal
  alias LawSpec.Data.LawspecCollectionsTypeEntry, as: KeyValEntry
  alias LawSpec.Data.Processed
  alias LawSpec.Data.Warning

  @doc "`Responses.process/3` of `text` over `chunks`, as a processed record."
  @spec process(binary(), [LawSpec.Data.indexed_chunk()]) :: LawSpec.Data.processed()
  def process(text, chunks) when is_binary(text) and is_list(chunks) do
    %Result{} =
      result = Quiet.quietly(fn -> Responses.process(text, to_indexed_chunks(chunks)) end)

    %Processed{
      raw_text: result.raw_text,
      final_text: result.final_text,
      chunk_map: to_key_val(result.chunk_map),
      citations: Enum.map(result.citations, &to_cited/1),
      media_count: length(result.media),
      actions: Enum.map(result.actions, &to_action/1),
      warnings: Enum.map(result.warnings, &to_warning/1)
    }
  end

  @doc "`Responses.build_citation_map/1` of `chunks`, as a key-value collection."
  @spec citation_map([LawSpec.Data.indexed_chunk()]) ::
          LawSpec.Data.key_val(non_neg_integer(), LawSpec.Data.citable_meta())
  def citation_map(chunks) when is_list(chunks) do
    chunks
    |> to_indexed_chunks()
    |> Responses.build_citation_map()
    |> to_key_val()
  end

  defp to_indexed_chunks(chunks) do
    provenance = %Provenance{search_type: :hybrid, query_text: "laws"}

    Enum.map(chunks, fn %IndexedChunk{index: index, meta: meta} ->
      {index,
       %Cake.Search.Result{
         retrieval_unit: FakeUnit.new(meta, ""),
         hit_source: :search,
         index: "laws",
         provenance: provenance,
         prompt_index: index
       }}
    end)
  end

  # LawSpec's KeyVal holds its entries in key order.
  defp to_key_val(chunk_map) when is_map(chunk_map) do
    entries =
      chunk_map
      |> Enum.sort_by(fn {index, _metadata} -> index end)
      |> Enum.map(fn {index, metadata} ->
        %KeyValEntry{key: index, value: FakeUnit.to_citable_meta(metadata)}
      end)

    %KeyVal{value: entries}
  end

  defp to_cited(%{old_index: old_index, new_index: new_index} = citation) do
    %Cited{
      old_index: old_index,
      new_index: new_index,
      meta: FakeUnit.to_citable_meta(citation)
    }
  end

  defp to_action(%{kind: kind, label: label, source_ref: source_ref}) do
    %Action{kind: to_action_kind(kind), label: label, source_ref: source_ref}
  end

  defp to_action_kind(:download), do: %LawSpec.Data.ActionKindDownload{}
  defp to_action_kind(:external_link), do: %LawSpec.Data.ActionKindExternalLink{}

  defp to_warning({:hallucinated_citation, index}), do: %Warning{value: index}
end
