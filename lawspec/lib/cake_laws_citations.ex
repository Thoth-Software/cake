# User-owned LawSpec adapter for laws/citations.lawspec.
defmodule Cake.Laws.Citations do
  @moduledoc """
  Adapts `Cake.Citations.extract/2` to the `cake.laws.citations` unit.

  The chunk map arrives as LawSpec's `KeyVal` of generated metadata records.
  Each record becomes a `Cake.Citable` metadata map through
  `Cake.Laws.FakeUnit`, so the map `extract/2` sees has the same five-key
  shape a real retrieval unit gives, and each citation's metadata is turned
  back into a record for the laws to compare.

  `extract/2` logs a warning per hallucinated index. Generated text
  hallucinates constantly, so the adapter raises this process's log level
  for the call; the warning is operational noise here, not part of any law.
  """

  alias Cake.Citations
  alias Cake.Laws.FakeUnit
  alias LawSpec.Data.Citation
  alias LawSpec.Data.Extraction
  alias LawSpec.Data.KeyVal
  alias LawSpec.Data.LawspecCollectionsTypeEntry, as: KeyValEntry

  @doc "`Citations.extract/2` of `text` against `chunk_map`, as an extraction record."
  @spec extract(binary(), LawSpec.Data.key_val(non_neg_integer(), LawSpec.Data.citable_meta())) ::
          LawSpec.Data.extraction()
  def extract(text, %KeyVal{} = chunk_map) when is_binary(text) do
    {valid, hallucinated} = quietly(fn -> Citations.extract(text, to_chunk_map(chunk_map)) end)

    %Extraction{
      valid: Enum.map(valid, &to_citation/1),
      hallucinated: hallucinated
    }
  end

  defp to_chunk_map(%KeyVal{value: entries}) do
    Map.new(entries, fn %KeyValEntry{key: index, value: meta} ->
      {index, meta |> FakeUnit.new("") |> Cake.Citable.metadata()}
    end)
  end

  defp to_citation(%{index: index, metadata: metadata}) do
    %Citation{index: index, metadata: FakeUnit.to_citable_meta(metadata)}
  end

  defp quietly(fun) do
    Logger.put_process_level(self(), :error)

    try do
      fun.()
    after
      Logger.delete_process_level(self())
    end
  end
end
