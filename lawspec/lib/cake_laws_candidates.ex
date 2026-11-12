# User-owned LawSpec adapter for laws/candidates.lawspec.
defmodule Cake.Laws.Candidates do
  @moduledoc """
  Adapts `Cake.Candidates` to the `cake.laws.candidates` unit.

  Each generated candidate becomes what `Cake.Conversation` broadcasts: a
  `Cake.Search.Result` whose retrieval unit is a `Cake.Laws.FakeUnit` carrying
  the candidate's `Cake.Citable` metadata. The fake is built directly, not
  with `FakeUnit.new/2`, because a candidate has `:extras`. Groups go back to
  Cake as the `{doc_id, results}` pairs
  `group_by_document/1` returns, and what Cake returns is read back through
  `Cake.Citable.metadata/1` into records the laws can compare.

  The translation is strict on purpose, so a shape the specification does
  not name fails the law instead of passing through: a document id, a title
  or a chunk id that is not a binary has no clause here.
  """

  alias Cake.Candidates
  alias Cake.Laws.FakeUnit
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias LawSpec.Data.Candidate
  alias LawSpec.Data.DocumentGroup
  alias LawSpec.Data.DocumentSummary

  @doc "`Candidates.group_by_document/1` of `candidates`, as group records."
  @spec group_by_document([LawSpec.Data.candidate()]) :: [LawSpec.Data.document_group()]
  def group_by_document(candidates) when is_list(candidates) do
    candidates
    |> Enum.map(&to_result/1)
    |> Candidates.group_by_document()
    |> Enum.map(&to_group/1)
  end

  @doc "`Candidates.document_metadata/1` of one group's `candidates`, as a summary record."
  @spec document_metadata([LawSpec.Data.candidate()]) :: LawSpec.Data.document_summary()
  def document_metadata(candidates) when is_list(candidates) do
    %{title: title, preview: preview, page_label: page_label} =
      candidates
      |> Enum.map(&to_result/1)
      |> Candidates.document_metadata()

    to_summary(title, preview, page_label)
  end

  @doc "`Candidates.expand_to_chunk_ids/2` of `selection` over `groups`."
  @spec expand_to_chunk_ids([binary()], [LawSpec.Data.document_group()]) :: [binary()]
  def expand_to_chunk_ids(selection, groups) when is_list(selection) and is_list(groups) do
    selection
    |> Candidates.expand_to_chunk_ids(Enum.map(groups, &from_group/1))
    |> Enum.map(&to_id/1)
  end

  @doc "`Candidates.all_chunk_ids/1` of `groups`."
  @spec all_chunk_ids([LawSpec.Data.document_group()]) :: [binary()]
  def all_chunk_ids(groups) when is_list(groups) do
    groups
    |> Enum.map(&from_group/1)
    |> Candidates.all_chunk_ids()
    |> Enum.map(&to_id/1)
  end

  defp to_result(%Candidate{} = candidate) do
    %Result{
      retrieval_unit: %FakeUnit{
        metadata: %{
          id: candidate.id,
          label: candidate.label,
          preview: candidate.preview,
          source_ref: from_maybe(candidate.source_ref),
          extras: to_extras(candidate.page, candidate.book_title)
        },
        prompt_context: ""
      },
      hit_source: :search,
      index: "laws",
      provenance: %Provenance{search_type: :hybrid, query_text: "laws"}
    }
  end

  defp to_candidate(%Result{retrieval_unit: unit}) do
    metadata = Cake.Citable.metadata(unit)

    %Candidate{
      id: to_id(metadata.id),
      label: metadata.label,
      preview: metadata.preview,
      source_ref: to_maybe(metadata.source_ref),
      page: fetch_maybe(metadata.extras, :page_number),
      book_title: fetch_maybe(metadata.extras, :book_title)
    }
  end

  defp to_group({doc_id, results}) when is_binary(doc_id) and is_list(results) do
    %DocumentGroup{doc_id: doc_id, members: Enum.map(results, &to_candidate/1)}
  end

  defp from_group(%DocumentGroup{doc_id: doc_id, members: members}) do
    {doc_id, Enum.map(members, &to_result/1)}
  end

  defp to_summary(title, preview, page_label) when is_binary(title) and is_binary(preview) do
    %DocumentSummary{title: title, preview: preview, page_label: to_maybe(page_label)}
  end

  defp to_id(id) when is_binary(id), do: id

  # An absent extra is a missing key, as in a retrieval unit that has none.
  defp to_extras(page, book_title) do
    for {key, {:present, value}} <- [page_number: page, book_title: book_title], into: %{} do
      {key, value}
    end
  end

  defp fetch_maybe(extras, key) do
    case Map.fetch(extras, key) do
      {:ok, value} -> {:present, value}
      :error -> :absent
    end
  end

  defp from_maybe(:absent), do: nil
  defp from_maybe({:present, value}), do: value

  defp to_maybe(nil), do: :absent
  defp to_maybe(value), do: {:present, value}
end
