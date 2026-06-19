defmodule Cake.CandidatesTest do
  @moduledoc """
  Pins the `Cake.Candidates` contract. `Candidates` consumes the
  `Cake.Search.Result` structs that `Cake.Conversation` broadcasts as manual-mode
  candidates — NOT bare `{chunk, scores}` tuples — and the document ids it groups
  on are strings, so they match the stringified ids the selection form returns.
  """
  use ExUnit.Case, async: true

  import Cake.Factory

  alias Cake.Candidates
  alias Cake.Search.Provenance
  alias Cake.Search.Result

  defp result(unit) do
    %Result{
      retrieval_unit: unit,
      backend_score: 1.0,
      hit_source: :search,
      index: "test_index",
      provenance: %Provenance{search_type: :hybrid, query_text: "q"}
    }
  end

  defp chunk(id, doc_ref, extras \\ %{}) do
    build(:convo_chunk,
      metadata: chunk_metadata(id: id, source_ref: doc_ref, label: doc_ref, extras: extras)
    )
  end

  describe "group_by_document/1" do
    test "groups Result structs by document (source_ref), preserving order" do
      results = [
        result(chunk("c1", "doc-A")),
        result(chunk("c2", "doc-B")),
        result(chunk("c3", "doc-A"))
      ]

      grouped = Candidates.group_by_document(results)

      assert [{"doc-A", a_results}, {"doc-B", b_results}] = grouped
      assert Enum.map(a_results, & &1.retrieval_unit.metadata.id) == ["c1", "c3"]
      assert Enum.map(b_results, & &1.retrieval_unit.metadata.id) == ["c2"]
    end

    test "falls back to chunk id when source_ref is nil, and keys are strings" do
      grouped = Candidates.group_by_document([result(chunk("c1", nil))])
      assert [{"c1", _}] = grouped
    end
  end

  describe "expand_to_chunk_ids/2" do
    test "maps selected document ids to their chunk ids" do
      grouped =
        Candidates.group_by_document([
          result(chunk("c1", "doc-A")),
          result(chunk("c2", "doc-B")),
          result(chunk("c3", "doc-A"))
        ])

      assert Candidates.expand_to_chunk_ids(["doc-A"], grouped) == ["c1", "c3"]
      assert Candidates.expand_to_chunk_ids(["doc-A", "doc-B"], grouped) == ["c1", "c3", "c2"]
    end

    test "unknown document ids contribute no chunks" do
      grouped = Candidates.group_by_document([result(chunk("c1", "doc-A"))])
      assert Candidates.expand_to_chunk_ids(["doc-missing"], grouped) == []
    end
  end

  describe "all_chunk_ids/1" do
    test "returns every chunk id across all documents" do
      grouped =
        Candidates.group_by_document([
          result(chunk("c1", "doc-A")),
          result(chunk("c2", "doc-B"))
        ])

      assert Candidates.all_chunk_ids(grouped) == ["c1", "c2"]
    end
  end

  describe "document_metadata/1" do
    test "summarizes a document's chunks with a page range" do
      results = [
        result(chunk("c1", "doc-A", %{page_number: 5, book_title: "The Book"})),
        result(chunk("c2", "doc-A", %{page_number: 2, book_title: "The Book"}))
      ]

      meta = Candidates.document_metadata(results)

      assert meta.title == "The Book"
      assert meta.page_label == "PDF pages 2-5"
    end

    test "single page renders a single-page label" do
      results = [result(chunk("c1", "doc-A", %{page_number: 7}))]
      assert Candidates.document_metadata(results).page_label == "PDF page 7"
    end

    test "no page numbers renders no page label" do
      results = [result(chunk("c1", "doc-A"))]
      assert Candidates.document_metadata(results).page_label == nil
    end
  end
end
