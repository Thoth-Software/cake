defmodule Cake.CandidatesTest do
  @moduledoc """
  Unit coverage for `Cake.Candidates`, the module that groups scored search
  units by document and maps a manual selection back to chunk ids.

  The `expand_to_chunk_ids/2` tests pin the contract that the selection form
  relies on: `ChatLive` builds the form's doc ids via `to_string(doc_id)`, so
  the lookup must key on the same stringified form. Keying on the raw term
  silently yields no chunks when the id is not already a plain string (#168).
  """

  use ExUnit.Case, async: true

  import Cake.Factory, only: [chunk_metadata: 1]

  alias Cake.Candidates
  alias Cake.Citable
  alias Cake.Test.ConvoChunk

  defp chunk(meta_overrides) do
    %ConvoChunk{metadata: chunk_metadata(meta_overrides)}
  end

  defp scored(meta_overrides), do: {chunk(meta_overrides), %{score: 1.0}}

  describe "group_by_document/1" do
    test "groups scored chunks by source_ref, preserving first-seen document order" do
      candidates = [
        scored(id: "a", source_ref: "doc-1"),
        scored(id: "b", source_ref: "doc-2"),
        scored(id: "c", source_ref: "doc-1")
      ]

      assert [{"doc-1", doc1_chunks}, {"doc-2", doc2_chunks}] =
               Candidates.group_by_document(candidates)

      assert doc1_chunks |> Enum.map(fn {ch, _} -> Citable.metadata(ch).id end) |> Enum.sort() ==
               ["a", "c"]

      assert [{ch, _}] = doc2_chunks
      assert Citable.metadata(ch).id == "b"
    end

    test "falls back to the chunk id when source_ref is nil" do
      assert [{"only-id", _}] =
               Candidates.group_by_document([scored(id: "only-id", source_ref: nil)])
    end
  end

  describe "expand_to_chunk_ids/2" do
    test "matches form-stringified ids against non-string candidate keys" do
      # The grouped key is an integer (a non-string term); the form submits "1".
      candidates = [{1, [scored(id: "chunk-a", source_ref: nil)]}]

      assert Candidates.expand_to_chunk_ids(["1"], candidates) == ["chunk-a"]
    end

    test "returns chunk ids only for the selected documents" do
      candidates = [
        {"doc-1", [scored(id: "a", source_ref: "doc-1")]},
        {"doc-2", [scored(id: "b", source_ref: "doc-2")]}
      ]

      assert Candidates.expand_to_chunk_ids(["doc-1"], candidates) == ["a"]
    end

    test "yields no chunks for an unknown doc id" do
      candidates = [{"doc-1", [scored(id: "a", source_ref: "doc-1")]}]
      assert Candidates.expand_to_chunk_ids(["nope"], candidates) == []
    end
  end

  describe "all_chunk_ids/1" do
    test "flattens every chunk id across all documents" do
      candidates = [
        {"doc-1", [scored(id: "a", source_ref: "doc-1")]},
        {"doc-2", [scored(id: "b", source_ref: "doc-2")]}
      ]

      assert Candidates.all_chunk_ids(candidates) == ["a", "b"]
    end
  end
end
