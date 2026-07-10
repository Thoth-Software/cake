defmodule Cake.CandidatesPropertyTest do
  @moduledoc """
  Property tests for `Cake.Candidates`.

  Pins grouping, expansion, and metadata invariants for the four public
  functions: `group_by_document/1`, `expand_to_chunk_ids/2`,
  `all_chunk_ids/1`, and `document_metadata/1`.

  Each generated Result carries a unique `prompt_index` tag (set during
  generation, not by the function under test) so partition and ordering
  properties can compare by identity without coupling to metadata fields.

  Example tests live in `candidates_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Candidates
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Test.ConvoChunk

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  defp build_extras(page_number, book_title) do
    [page_number: page_number, book_title: book_title]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_result(chunk_id, source_ref, page_number, book_title, preview_text) do
    %Result{
      retrieval_unit: %ConvoChunk{
        metadata: %{
          id: chunk_id,
          label: book_title || "untitled",
          preview: preview_text,
          source_ref: source_ref,
          extras: build_extras(page_number, book_title)
        }
      },
      backend_score: 1.0,
      hit_source: :search,
      index: "test_index",
      provenance: test_provenance()
    }
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp doc_id do
    string(:alphanumeric, min_length: 1, max_length: 8)
  end

  defp result_attrs do
    gen all(
          page_number <- one_of([constant(nil), integer(1..200)]),
          book_title <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 20)]),
          preview_text <- string(:alphanumeric, max_length: 250)
        ) do
      %{page_number: page_number, book_title: book_title, preview_text: preview_text}
    end
  end

  defp source_ref_in_pool(pool) do
    one_of([constant(nil)] ++ Enum.map(pool, &constant/1))
  end

  defp result_in_pool(pool) do
    gen all(
          chunk_id <- string(:alphanumeric, min_length: 1, max_length: 12),
          source_ref <- source_ref_in_pool(pool),
          attrs <- result_attrs()
        ) do
      build_result(chunk_id, source_ref, attrs.page_number, attrs.book_title, attrs.preview_text)
    end
  end

  defp results_list do
    gen all(
          pool <- list_of(doc_id(), min_length: 1, max_length: 4),
          raw_results <- list_of(result_in_pool(pool), min_length: 1, max_length: 12)
        ) do
      raw_results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> %{r | prompt_index: i} end)
    end
  end

  defp result_for_single_doc(source_ref) do
    gen all(
          chunk_id <- string(:alphanumeric, min_length: 1, max_length: 12),
          attrs <- result_attrs()
        ) do
      build_result(chunk_id, source_ref, attrs.page_number, attrs.book_title, attrs.preview_text)
    end
  end

  defp single_doc_results do
    gen all(
          source_ref <- doc_id(),
          results <- list_of(result_for_single_doc(source_ref), min_length: 1, max_length: 6)
        ) do
      results
    end
  end

  # ---------------------------------------------------------------------------
  # group_by_document/1 properties
  # ---------------------------------------------------------------------------

  property "group_by_document/1 is a partition — every input appears in exactly one group" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)
      flattened = Enum.flat_map(grouped, fn {_doc_id, rs} -> rs end)

      input_tags = results |> Enum.map(& &1.prompt_index) |> Enum.sort()
      output_tags = flattened |> Enum.map(& &1.prompt_index) |> Enum.sort()

      assert input_tags == output_tags
    end
  end

  property "group_by_document/1 within-group order matches input order" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)

      Enum.each(grouped, fn {_doc_id, group_results} ->
        tags = Enum.map(group_results, & &1.prompt_index)
        assert tags == Enum.sort(tags)
      end)
    end
  end

  property "group_by_document/1 groups appear in first-appearance order" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)

      first_tags =
        Enum.map(grouped, fn {_doc_id, group_results} ->
          group_results |> Enum.map(& &1.prompt_index) |> Enum.min()
        end)

      assert first_tags == Enum.sort(first_tags)
    end
  end

  property "group_by_document/1 keys are all strings" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)
      Enum.each(grouped, fn {doc_id, _} -> assert is_binary(doc_id) end)
    end
  end

  # ---------------------------------------------------------------------------
  # expand_to_chunk_ids/2 and all_chunk_ids/1 properties
  # ---------------------------------------------------------------------------

  property "expand_to_chunk_ids with all doc_ids equals all_chunk_ids" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)
      all_doc_ids = Enum.map(grouped, fn {doc_id, _} -> doc_id end)

      assert Candidates.expand_to_chunk_ids(all_doc_ids, grouped) ==
               Candidates.all_chunk_ids(grouped)
    end
  end

  property "expand_to_chunk_ids with empty selection returns []" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)
      assert Candidates.expand_to_chunk_ids([], grouped) == []
    end
  end

  property "all_chunk_ids/1 count equals total number of results" do
    check all(results <- results_list()) do
      grouped = Candidates.group_by_document(results)
      assert length(Candidates.all_chunk_ids(grouped)) == length(results)
    end
  end

  # ---------------------------------------------------------------------------
  # document_metadata/1 properties
  # ---------------------------------------------------------------------------

  property "document_metadata/1 preview is at most 100 characters" do
    check all(results <- single_doc_results()) do
      meta = Candidates.document_metadata(results)
      assert String.length(meta.preview) <= 100
    end
  end

  property "document_metadata/1 page_label matches expected format" do
    check all(results <- single_doc_results()) do
      meta = Candidates.document_metadata(results)

      case meta.page_label do
        nil ->
          :ok

        label ->
          assert Regex.match?(~r/^PDF page \d+$/, label) or
                   Regex.match?(~r/^PDF pages \d+-\d+$/, label)
      end
    end
  end

  property "document_metadata/1 page range has min <= max" do
    check all(results <- single_doc_results()) do
      meta = Candidates.document_metadata(results)

      case meta.page_label do
        "PDF pages " <> range ->
          [min_s, max_s] = String.split(range, "-")
          assert String.to_integer(min_s) <= String.to_integer(max_s)

        _ ->
          :ok
      end
    end
  end
end
