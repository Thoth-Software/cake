defmodule Cake.Books.RetrievalPropertyTest do
  @moduledoc """
  Property tests for `Cake.Books.Retrieval.expand_with_neighbors/2`, the
  Books GDS's neighbour expansion, against real Postgres rows.

  For one or two books of N chunks each, a random subset of hits and a random
  offset, the expansion must return exactly the chunks within `offset`
  positions of a hit in the same book: every hit, every neighbour, nothing
  else, no duplicates, each with its book preloaded, and within each book in
  ascending `chunk_index` order so a caller knows which neighbours precede
  and follow a hit. The round-trip integration test in
  `search/gds_round_trip_integration_test.exs` pins one worked example
  against the real index.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  import Cake.BooksFixtures

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Retrieval

  # Each iteration seeds its own books, so the run count is kept modest.
  @max_runs 40

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # One book: its chunk count and the positions of the hits within it, as a
  # hit flag per chunk (no filtering, so no narrow-filter failures).
  defp book_plan do
    gen all(
          size <- integer(1..8),
          flags <- list_of(boolean(), length: size)
        ) do
      positions = for {true, index} <- Enum.with_index(flags), do: index
      %{size: size, hit_positions: positions}
    end
  end

  # One or two books, plus the offset. With no hit anywhere, the first chunk
  # of the first book becomes one, so every case has something to expand.
  defp expansion_case do
    gen all(
          plans <- list_of(book_plan(), min_length: 1, max_length: 2),
          offset <- integer(0..4)
        ) do
      plans =
        if Enum.all?(plans, &(&1.hit_positions == [])) do
          List.update_at(plans, 0, &%{&1 | hit_positions: [0]})
        else
          plans
        end

      %{plans: plans, offset: offset}
    end
  end

  # Seeds the books and returns `{all_chunks, hits}`, hits in a shuffled
  # order so the expansion cannot lean on hit order.
  defp seed!(plans) do
    seeded =
      Enum.map(plans, fn plan ->
        {_book, chunks} = book_with_chunks_fixture(List.duplicate(%{}, plan.size))
        {chunks, Enum.map(plan.hit_positions, &Enum.at(chunks, &1))}
      end)

    {Enum.flat_map(seeded, &elem(&1, 0)), seeded |> Enum.flat_map(&elem(&1, 1)) |> Enum.shuffle()}
  end

  defp within_offset?(chunk, hits, offset) do
    Enum.any?(hits, fn hit ->
      hit.parsed_book_id == chunk.parsed_book_id and
        abs(hit.chunk_index - chunk.chunk_index) <= offset
    end)
  end

  defp ids(chunks), do: chunks |> Enum.map(& &1.id) |> Enum.sort()

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "returns exactly the chunks within offset of a hit in the same book, once each" do
    check all(%{plans: plans, offset: offset} <- expansion_case(), max_runs: @max_runs) do
      {all_chunks, hits} = seed!(plans)

      expanded = Retrieval.expand_with_neighbors(hits, offset)

      assert ids(expanded) == ids(Enum.filter(all_chunks, &within_offset?(&1, hits, offset)))
      assert ids(expanded) == expanded |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()
    end
  end

  property "every hit is in its own expansion" do
    check all(%{plans: plans, offset: offset} <- expansion_case(), max_runs: @max_runs) do
      {_all_chunks, hits} = seed!(plans)

      expanded_ids = hits |> Retrieval.expand_with_neighbors(offset) |> ids()

      assert Enum.all?(hits, &(&1.id in expanded_ids))
    end
  end

  property "every returned chunk has its book preloaded" do
    check all(%{plans: plans, offset: offset} <- expansion_case(), max_runs: @max_runs) do
      {_all_chunks, hits} = seed!(plans)

      assert hits
             |> Retrieval.expand_with_neighbors(offset)
             |> Enum.all?(&match?(%Chunk{parsed_book: %ParsedBook{}}, &1))
    end
  end

  property "within each book the returned chunks are in ascending chunk_index order" do
    check all(%{plans: plans, offset: offset} <- expansion_case(), max_runs: @max_runs) do
      {_all_chunks, hits} = seed!(plans)

      per_book =
        hits
        |> Retrieval.expand_with_neighbors(offset)
        |> Enum.group_by(& &1.parsed_book_id, & &1.chunk_index)

      for {_book_id, indices} <- per_book do
        assert indices == Enum.sort(indices)
      end
    end
  end

  property "an offset of zero returns exactly the hits" do
    check all(%{plans: plans} <- expansion_case(), max_runs: @max_runs) do
      {_all_chunks, hits} = seed!(plans)

      assert hits |> Retrieval.expand_with_neighbors(0) |> ids() == ids(hits)
    end
  end
end
