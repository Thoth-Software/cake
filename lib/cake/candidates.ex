defmodule Cake.Candidates do
  @moduledoc false

  alias Cake.Citable

  @type scored_chunk :: {struct(), map()}
  @type grouped :: [{term(), [scored_chunk()]}]

  @spec group_by_document([scored_chunk()]) :: grouped()
  def group_by_document(candidates) do
    candidates
    |> Enum.reduce([], fn {chunk, _scores} = entry, acc ->
      doc_id = doc_id_for(chunk)

      case List.keyfind(acc, doc_id, 0) do
        nil -> [{doc_id, [entry]} | acc]
        {^doc_id, existing} -> List.keyreplace(acc, doc_id, 0, {doc_id, [entry | existing]})
      end
    end)
    |> Enum.reverse()
  end

  defp doc_id_for(chunk) do
    meta = Citable.metadata(chunk)
    meta.source_ref || meta.id
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
    # The selection form carries doc ids as strings (ChatLive builds them with
    # to_string/1), so the lookup is keyed by the same stringified form. Keying
    # on the raw term silently misses whenever a doc id is not already a plain
    # string.
    lookup = Map.new(candidates, fn {doc_id, chunks} -> {to_string(doc_id), chunks} end)

    Enum.flat_map(selected_doc_ids, fn doc_id ->
      chunks = Map.get(lookup, to_string(doc_id), [])
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
