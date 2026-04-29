defmodule Cake.PipelinesPropertyTest do
  @moduledoc """
  Property tests for `Cake.Pipelines` error and stream helpers.

  Pins the contract of `handle_ingest_error/2` (both 2-tuple and 3-tuple
  shapes) and `detuple_with_logging/3` against arbitrary inputs, surfacing
  `inspect/1` formatting surprises (charlists, structs, nested maps) and
  ordering/count invariants that example tests would miss.

  Per CLAUDE.md, property tests cover pure-ish functions; the side effect
  here is a `FailedIngest` insert per error tuple. Iterations within a single
  property accumulate rows in the same sandbox, so assertions are written as
  exact-match deltas rather than fetching "the latest row."
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  alias Cake.FailedIngests.FailedIngest
  alias Cake.Pipelines
  alias Cake.Repo

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp reason_term do
    one_of([
      binary(),
      atom(:alphanumeric),
      integer(),
      list_of(byte(), max_length: 16),
      map_of(atom(:alphanumeric), binary(), max_length: 4),
      tuple({atom(:alphanumeric), binary()})
    ])
  end

  defp step_atom do
    one_of([
      constant(:download),
      constant(:parse),
      constant(:embed),
      constant(:index),
      atom(:alphanumeric)
    ])
  end

  # Unique-per-iteration version string keeps property iterations from
  # colliding on row filters even when the random generator happens to
  # repeat short versions.
  defp context do
    gen all(
          version_seed <- string(:alphanumeric, min_length: 1, max_length: 8),
          opts <- list_of(tuple({atom(:alphanumeric), binary()}), max_length: 3)
        ) do
      version =
        version_seed <>
          "-" <>
          Integer.to_string(System.unique_integer([:positive]))

      Pipelines.build_context(
        Cake.Documents.Pipeline,
        Cake.TestPipeline,
        version,
        opts
      )
    end
  end

  defp count_matching(filters) do
    base = from(f in FailedIngest, select: count(f.id))

    query =
      Enum.reduce(filters, base, fn {field, value}, q ->
        from(f in q, where: field(f, ^field) == ^value)
      end)

    Repo.one(query)
  end

  # ---------------------------------------------------------------------------
  # handle_ingest_error/2 — 3-tuple branch
  # ---------------------------------------------------------------------------

  describe "handle_ingest_error/2 with {:error, step, reason}" do
    property "returns {:error, {step, reason}} and persists exactly one matching fatal row" do
      check all(
              ctx <- context(),
              step <- step_atom(),
              reason <- reason_term()
            ) do
        filters = [
          pipeline_implementation: ctx.implementation,
          version: ctx.version,
          step: Atom.to_string(step),
          error_text: inspect(reason),
          pipeline_fatal: true
        ]

        before_count = count_matching(filters)

        result = Pipelines.handle_ingest_error({:error, step, reason}, ctx)

        assert result == {:error, {step, reason}}
        assert count_matching(filters) == before_count + 1
      end
    end
  end

  # ---------------------------------------------------------------------------
  # handle_ingest_error/2 — 2-tuple branch
  # ---------------------------------------------------------------------------

  describe "handle_ingest_error/2 with {:error, reason}" do
    property "persists exactly one matching fatal row tagged step \"ingest\"" do
      check all(
              ctx <- context(),
              reason <- reason_term()
            ) do
        filters = [
          pipeline_implementation: ctx.implementation,
          version: ctx.version,
          step: "ingest",
          error_text: inspect(reason),
          pipeline_fatal: true
        ]

        before_count = count_matching(filters)

        _ = Pipelines.handle_ingest_error({:error, reason}, ctx)

        assert count_matching(filters) == before_count + 1
      end
    end
  end

  # ---------------------------------------------------------------------------
  # detuple_with_logging/3
  # ---------------------------------------------------------------------------

  describe "detuple_with_logging/3" do
    property "passes through every {:ok, value} in input order" do
      check all(
              ctx <- context(),
              step_name <- string(:alphanumeric, min_length: 1, max_length: 16),
              values <- list_of(integer(), max_length: 32)
            ) do
        input = Enum.map(values, fn v -> {:ok, v} end)

        output =
          input
          |> Pipelines.detuple_with_logging(step_name, ctx)
          |> Enum.to_list()

        assert output == values
      end
    end

    property "drops every {:error, _} and persists one non-fatal row per error" do
      check all(
              ctx <- context(),
              step_name <- string(:alphanumeric, min_length: 1, max_length: 16),
              entries <-
                list_of(
                  one_of([
                    tuple({constant(:ok), integer()}),
                    tuple({constant(:error), reason_term()})
                  ]),
                  max_length: 16
                )
            ) do
        oks = Enum.filter(entries, &match?({:ok, _}, &1))
        errs = Enum.filter(entries, &match?({:error, _}, &1))

        filters = [
          pipeline_implementation: ctx.implementation,
          version: ctx.version,
          step: step_name,
          pipeline_fatal: false
        ]

        before_count = count_matching(filters)

        output =
          entries
          |> Pipelines.detuple_with_logging(step_name, ctx)
          |> Enum.to_list()

        assert output == Enum.map(oks, fn {:ok, v} -> v end)
        assert count_matching(filters) == before_count + length(errs)
      end
    end
  end
end
