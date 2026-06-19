defmodule Cake.Candidates do
  @moduledoc false

  # Domain-level grouping for the manual-selection UI. Consumes the
  # `Cake.Search.Result` structs that `Cake.Conversation` broadcasts as
  # candidates (everything above the search boundary speaks `Result`), groups
  # them by document, and expands a document selection back into chunk ids for
  # `Conversation.select_docs/2`.
  #
  # Document ids are stringified so they round-trip cleanly through the HTML
  # selection form, which always hands ids back as strings.

  alias Cake.Citable
  alias Cake.Search.Result

  @type doc_id :: String.t()
  @type grouped :: [{doc_id(), [Result.t()]}]

  @spec group_by_document([Result.t()]) :: grouped()
  def group_by_document(results) do
    results
    |> Enum.reduce([], fn %Result{} = result, acc ->
      doc_id = doc_id_for(result)

      case List.keyfind(acc, doc_id, 0) do
        nil -> [{doc_id, [result]} | acc]
        {^doc_id, existing} -> List.keyreplace(acc, doc_id, 0, {doc_id, [result | existing]})
      end
    end)
    |> Enum.map(fn {doc_id, results} -> {doc_id, Enum.reverse(results)} end)
    |> Enum.reverse()
  end

  @spec doc_id_for(Result.t()) :: doc_id()
  defp doc_id_for(%Result{retrieval_unit: unit}) do
    meta = Citable.metadata(unit)
    to_string(meta.source_ref || meta.id)
  end

  @spec document_metadata([Result.t()]) :: %{
          title: String.t() | nil,
          preview: String.t(),
          page_label: String.t() | nil
        }
  def document_metadata([%Result{retrieval_unit: first} | _] = results) do
    meta = Citable.metadata(first)

    page_numbers =
      results
      |> Enum.map(fn %Result{retrieval_unit: unit} ->
        Citable.metadata(unit).extras[:page_number]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    page_label =
      case page_numbers do
        [] -> nil
        [p] -> "PDF page #{p}"
        pages -> "PDF pages #{List.first(pages)}-#{List.last(pages)}"
      end

    %{
      title: meta.extras[:book_title] || meta.label,
      preview: String.slice(meta.preview, 0, 100),
      page_label: page_label
    }
  end

  @spec expand_to_chunk_ids([doc_id()], grouped()) :: [term()]
  def expand_to_chunk_ids(selected_doc_ids, grouped) do
    lookup = Map.new(grouped)

    Enum.flat_map(selected_doc_ids, fn doc_id ->
      lookup
      |> Map.get(to_string(doc_id), [])
      |> Enum.map(fn %Result{retrieval_unit: unit} -> Citable.metadata(unit).id end)
    end)
  end

  @spec all_chunk_ids(grouped()) :: [term()]
  def all_chunk_ids(grouped) do
    Enum.flat_map(grouped, fn {_doc_id, results} ->
      Enum.map(results, fn %Result{retrieval_unit: unit} -> Citable.metadata(unit).id end)
    end)
  end
end
