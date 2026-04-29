defmodule Cake.ResponsesTest do
  use Cake.DataCase, async: true

  alias Cake.Responses
  alias Cake.Responses.Result
  alias Cake.Search.Provenance
  alias Cake.Test.StubChunk

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  defp wrap_result(unit, opts \\ []) do
    %Cake.Search.Result{
      retrieval_unit: unit,
      backend_score: Keyword.get(opts, :backend_score, 1.0),
      hit_source: Keyword.get(opts, :hit_source, :search),
      index: "test_index",
      provenance: test_provenance()
    }
  end

  @meta_a %{
    id: {"a.pdf", 1},
    label: "Alpha, p. 1",
    preview: "alpha preview",
    source_ref: "a.pdf",
    extras: %{book_title: "Alpha", page_number: 1, section_title: nil, chunk_index: 1}
  }

  @meta_b %{
    id: {"b.pdf", 2},
    label: "Beta, p. 2",
    preview: "beta preview",
    source_ref: "b.pdf",
    extras: %{book_title: "Beta", page_number: 2, section_title: nil, chunk_index: 2}
  }

  @meta_c %{
    id: {"a.pdf", 3},
    label: "Alpha, p. 3",
    preview: "alpha-c preview",
    source_ref: "a.pdf",
    extras: %{book_title: "Alpha", page_number: 3, section_title: nil, chunk_index: 3}
  }

  describe "build_citation_map/1" do
    import Cake.BooksFixtures

    test "returns a map keyed by positive integers with Citable-shaped values" do
      chunk = Repo.preload(chunk_fixture(), :parsed_book)
      map = Responses.build_citation_map([{7, wrap_result(chunk, backend_score: 0.9)}])

      assert Map.keys(map) == [7]

      metadata = Map.fetch!(map, 7)

      assert metadata |> Map.keys() |> Enum.sort() ==
               [:extras, :id, :label, :preview, :source_ref]
    end

    test "delegates field production to Cake.Citable.metadata/1" do
      chunk = Repo.preload(chunk_fixture(), :parsed_book)

      direct = Cake.Citable.metadata(chunk)
      via_map = Map.fetch!(Responses.build_citation_map([{1, wrap_result(chunk)}]), 1)

      assert via_map == direct
    end
  end

  describe "process/3 — resolve stage" do
    test "populates citations with the Citable metadata from chunk_map" do
      indexed = fake_indexed(%{1 => @meta_a})
      result = Responses.process("Cite [1].", indexed_override(indexed, %{1 => @meta_a}))

      [citation] = result.citations
      assert citation.id == @meta_a.id
      assert citation.label == @meta_a.label
      assert citation.preview == @meta_a.preview
      assert citation.source_ref == @meta_a.source_ref
      assert citation.extras == @meta_a.extras
    end

    test "hallucinated indices surface as warnings" do
      indexed = indexed_override([], %{1 => @meta_a})
      result = Responses.process("Cite [1] and [99].", indexed)

      assert {:hallucinated_citation, 99} in result.warnings
    end
  end

  describe "process/3 — renumber stage" do
    test "assigns new_index by first-appearance order" do
      indexed = indexed_override([], %{3 => @meta_a, 5 => @meta_b})
      result = Responses.process("[3] first then [5].", indexed)

      [c1, c2] = result.citations
      assert {c1.old_index, c1.new_index} == {3, 1}
      assert {c2.old_index, c2.new_index} == {5, 2}
    end

    test "first-appearance beats later mentions of an earlier number" do
      indexed = indexed_override([], %{3 => @meta_a, 5 => @meta_b})
      result = Responses.process("[5] first then [3] then [5] again.", indexed)

      by_old = Map.new(result.citations, &{&1.old_index, &1.new_index})
      assert by_old == %{5 => 1, 3 => 2}
    end

    test "citations are sorted by new_index" do
      indexed = indexed_override([], %{3 => @meta_a, 5 => @meta_b, 7 => @meta_c})
      result = Responses.process("[7] then [3] then [5].", indexed)

      assert Enum.map(result.citations, & &1.new_index) == [1, 2, 3]
    end

    test "text with no citations yields an empty citations list" do
      indexed = indexed_override([], %{1 => @meta_a})
      result = Responses.process("No citations here.", indexed)

      assert result.citations == []
    end
  end

  describe "process/3 — rewrite stage" do
    test "renumbered citations replace original markers in final_text" do
      indexed = indexed_override([], %{3 => @meta_a, 5 => @meta_b})
      result = Responses.process("[3] foo [5] bar", indexed)

      assert result.final_text == "[1] foo [2] bar"
      assert result.raw_text == "[3] foo [5] bar"
    end

    test "hallucinated tokens are stripped and extra spaces collapse" do
      indexed = indexed_override([], %{3 => @meta_a})
      result = Responses.process("[3] foo [99] bar", indexed)

      assert result.final_text == "[1] foo bar"
    end
  end

  describe "process/3 — actions stage" do
    test "unique source_refs produce one download action each" do
      indexed = indexed_override([], %{1 => @meta_a, 2 => @meta_b})
      result = Responses.process("see [1] and [2]", indexed)

      kinds = Enum.uniq(Enum.map(result.actions, & &1.kind))
      assert kinds == [:download]

      refs = Enum.sort(Enum.map(result.actions, & &1.source_ref))
      assert refs == ["a.pdf", "b.pdf"]
    end

    test "citations with nil source_ref produce no action" do
      nil_meta = %{@meta_a | source_ref: nil}
      indexed = indexed_override([], %{1 => nil_meta})
      result = Responses.process("see [1]", indexed)

      assert result.actions == []
    end

    test "duplicate source_refs are deduplicated" do
      indexed = indexed_override([], %{1 => @meta_a, 3 => @meta_c})
      result = Responses.process("[1] and [3]", indexed)

      assert length(result.actions) == 1
      assert hd(result.actions).source_ref == "a.pdf"
    end
  end

  describe "process/3 — format stage" do
    test "collapses 3+ consecutive newlines to 2 and trims whitespace" do
      indexed = indexed_override([], %{1 => @meta_a})
      result = Responses.process("  \n\n\n\nFoo [1]\n\n\n  ", indexed)

      assert result.final_text == "Foo [1]"
    end
  end

  describe "process/3 — integration" do
    test "full pipeline on realistic input" do
      indexed = indexed_override([], %{3 => @meta_a, 5 => @meta_b})
      result = Responses.process("Intro [5]. Detail [3]. More [5] on topic.", indexed)

      assert result.final_text == "Intro [1]. Detail [2]. More [1] on topic."
      assert Enum.map(result.citations, & &1.new_index) == [1, 2]
      assert result.warnings == []
      assert length(result.actions) == 2
      assert result.media == []
    end

    test "hallucination path surfaces warning and strips token" do
      indexed = indexed_override([], %{1 => @meta_a})
      result = Responses.process("Cite [1] and also [99].", indexed)

      assert result.warnings == [{:hallucinated_citation, 99}]
      assert result.final_text == "Cite [1] and also ."
    end

    test "empty input yields a valid Result with empty fields" do
      result = Responses.process("", [])

      assert %Result{} = result
      assert result.raw_text == ""
      assert result.final_text == ""
      assert result.citations == []
      assert result.chunk_map == %{}
      assert result.actions == []
      assert result.media == []
      assert result.warnings == []
    end

    test "citations carry all seven fields" do
      indexed = indexed_override([], %{1 => @meta_a})
      result = Responses.process("see [1]", indexed)

      [c] = result.citations

      assert c |> Map.keys() |> Enum.sort() ==
               [:extras, :id, :label, :new_index, :old_index, :preview, :source_ref]
    end
  end

  # Builds an indexed_chunks list whose chunks carry a Citable impl that returns
  # the metadata map looked up by the chunk's own index. Keeps the tests pure —
  # no DB, no Books.Chunk coupling.
  defp indexed_override(_base, metadata_by_index) do
    Enum.map(metadata_by_index, fn {idx, meta} ->
      {idx, wrap_result(%StubChunk{metadata: meta})}
    end)
  end

  defp fake_indexed(metadata_by_index), do: indexed_override([], metadata_by_index)
end
