defmodule Cake.Citations do
  @moduledoc """
  Parses inline citation references from LLM response text and resolves them
  against the chunk_map produced by Cake.Responses.
  """

  require Logger

  @citation_pattern ~r/\[(\d+)\]/

  @doc """
  Extract citations from a response text using the provided chunk_map.

  Returns a deduplicated, sorted list of citation maps for each valid [N]
  reference found in the text.
  """
  def extract(response_text, chunk_map) do
    @citation_pattern
    |> Regex.scan(response_text)
    |> Enum.map(fn [_match, index_str] -> String.to_integer(index_str) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn index ->
      case Map.fetch(chunk_map, index) do
        {:ok,
         %{
           book_title: book_title,
           page_number: page_number,
           section_title: section_title,
           chunk_index: chunk_index,
           chunk_preview: chunk_preview,
           source_file_path: source_file_path
         }} ->
          [
            %{
              index: index,
              book_title: book_title,
              page_number: page_number,
              section_title: section_title,
              chunk_index: chunk_index,
              chunk_preview: chunk_preview,
              source_file_path: source_file_path
            }
          ]

        :error ->
          Logger.warning("Citation [#{index}] not found in chunk_map, dropping hallucinated citation")
          []
      end
    end)
  end
end
