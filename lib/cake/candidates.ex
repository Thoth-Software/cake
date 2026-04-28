defmodule Cake.Candidates do
  @moduledoc false

  alias Cake.Citable

  @type scored_chunk :: {struct(), map()}
  @type grouped :: %{optional(term()) => [scored_chunk()]}

  @spec group_by_document([scored_chunk()]) :: grouped()
  def group_by_document(candidates) do
    Enum.group_by(candidates, fn {chunk, _scores} ->
      meta = Citable.metadata(chunk)
      meta.source_ref || meta.id
    end)
  end

  @spec document_metadata([scored_chunk()]) :: %{
          title: String.t() | nil,
          preview: String.t(),
          page_label: String.t() | nil
        }
  def document_metadata(chunks) do
    {first_chunk, _scores} = hd(chunks)
    meta = Citable.metadata(first_chunk)

    page_numbers =
      chunks
      |> Enum.map(fn {chunk, _} -> Citable.metadata(chunk).extras[:page_number] end)
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

  @spec expand_to_chunk_ids([String.t()], grouped()) :: [term()]
  def expand_to_chunk_ids(selected_doc_ids, candidates) do
    Enum.flat_map(selected_doc_ids, fn doc_id ->
      chunks = Map.get(candidates, doc_id, [])
      Enum.map(chunks, fn {chunk, _scores} -> Citable.metadata(chunk).id end)
    end)
  end

  @spec all_chunk_ids(grouped()) :: [term()]
  def all_chunk_ids(candidates) do
    Enum.flat_map(candidates, fn {_doc_id, chunks} ->
      Enum.map(chunks, fn {chunk, _scores} -> Citable.metadata(chunk).id end)
    end)
  end
end
