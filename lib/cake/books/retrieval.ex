defmodule Cake.Books.Retrieval do
  @moduledoc """
  Read-path for the Books GDS: hydrates `Chunk` records from OpenSearch hits
  and expands a hit set with neighboring chunks from Postgres.

  These are the implementations `Cake.Books.ParsedBook` delegates to for the
  `Cake.GDS` `load_from_hits/1` and `expand_with_neighbors/2` callbacks. Kept
  out of the `Cake.Books` CRUD context because this is bespoke retrieval logic
  (ordered hydration, range merging), not generic record management.
  """

  import Ecto.Query, warn: false

  alias Cake.Books.Chunk
  alias Cake.Repo

  @doc """
  Fetches Chunk records for a list of OpenSearch hits, with `parsed_book`
  preloaded. Returns chunks in the same order as the hits.
  """
  @spec chunks_for_hits(%Snap.Hits{} | list()) :: [Chunk.t()]
  def chunks_for_hits(hits) do
    ids = Enum.map(hits, fn hit -> hit.source["id"] end)

    chunks_by_id =
      Map.new(
        Repo.all(from c in Chunk, where: c.id in ^ids, preload: :parsed_book),
        fn chunk -> {chunk.id, chunk} end
      )

    ids
    |> Enum.map(&Map.get(chunks_by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Expands a list of retrieved chunks by fetching neighboring chunks from Postgres.

  Given chunks returned by `chunks_for_hits/1`, this function:
  1. Groups them by `parsed_book_id`
  2. For each book, computes the union of chunk index ranges [index - offset, index + offset]
  3. Merges overlapping ranges to avoid redundant queries
  4. Fetches all chunks in those ranges from Postgres
  5. Returns a deduplicated, ordered list with `:parsed_book` preloaded

  The offset controls how many chunks on each side of a hit are included.
  An offset of 2 means each hit brings in up to 4 neighbors (2 before, 2 after),
  though in practice overlapping hits within the same book will merge into
  contiguous windows.

  ## Examples

      # Expand each hit by 2 chunks on each side
      chunks = Cake.Books.Retrieval.chunks_for_hits(hits)
      expanded = Cake.Books.Retrieval.expand_with_neighbors(chunks, 2)

  """
  @spec expand_with_neighbors([Chunk.t()], non_neg_integer()) :: [Chunk.t()]
  def expand_with_neighbors(chunks, offset)
      when is_list(chunks) and is_integer(offset) and offset >= 0 do
    chunks
    |> Enum.group_by(& &1.parsed_book_id)
    |> Enum.flat_map(fn {book_id, book_chunks} ->
      fetch_neighbor_ranges(book_id, book_chunks, offset)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp fetch_neighbor_ranges(book_id, book_chunks, offset) do
    book_chunks
    |> Enum.map(fn c -> {max(c.chunk_index - offset, 0), c.chunk_index + offset} end)
    |> Enum.sort()
    |> merge_ranges()
    |> Enum.flat_map(fn {low, high} ->
      Chunk.base_query()
      |> Chunk.by_book(book_id)
      |> where([c], c.chunk_index >= ^low and c.chunk_index <= ^high)
      |> order_by([c], asc: c.chunk_index)
      |> Repo.all()
      |> Repo.preload(:parsed_book)
    end)
  end

  # Merges a sorted list of {low, high} integer ranges into non-overlapping ranges.
  # Adjacent ranges (e.g., {1, 3} and {4, 6}) are also merged since chunk indices
  # are integers and index 3 and index 4 are contiguous.
  defp merge_ranges([]), do: []

  defp merge_ranges([first | rest]) do
    Enum.reverse(
      Enum.reduce(rest, [first], fn {low, high}, [{acc_low, acc_high} | tail] ->
        if low <= acc_high + 1 do
          [{acc_low, max(acc_high, high)} | tail]
        else
          [{low, high}, {acc_low, acc_high} | tail]
        end
      end)
    )
  end
end
