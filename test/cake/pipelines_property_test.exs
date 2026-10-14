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

  import ExUnit.CaptureLog, only: [with_log: 1]

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
          step_prefix <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 8)]),
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
        [step_prefix: step_prefix] ++ opts
      )
    end
  end

  # The step name a fatal row persists: the context's prefix, when it has
  # one, joined to the bare step with a dot.
  defp persisted_step(%{step_prefix: nil}, step), do: step
  defp persisted_step(%{step_prefix: prefix}, step), do: "#{prefix}.#{step}"

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
          run_id: ctx.run_id,
          pipeline_implementation: ctx.implementation,
          version: ctx.version,
          step: persisted_step(ctx, Atom.to_string(step)),
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
    property "persists exactly one matching fatal row tagged step \"ingest\" under the prefix" do
      check all(
              ctx <- context(),
              reason <- reason_term()
            ) do
        filters = [
          run_id: ctx.run_id,
          pipeline_implementation: ctx.implementation,
          version: ctx.version,
          step: persisted_step(ctx, "ingest"),
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
          run_id: ctx.run_id,
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

  # ---------------------------------------------------------------------------
  # sweep/3 — retry bookkeeping
  # ---------------------------------------------------------------------------

  defp insert_row(ctx, identifier) do
    {:ok, row} =
      Cake.FailedIngests.create_failed_ingest(%{
        run_id: ctx.run_id,
        pipeline_behaviour: ctx.behaviour,
        pipeline_implementation: ctx.implementation,
        step: "docs.embed",
        version: ctx.version,
        error_text: "boom",
        input_identifier: identifier,
        pipeline_fatal: false
      })

    row
  end

  describe "sweep/3" do
    property "every unresolved row records one attempt per pass; resolved rows are deleted" do
      check all(
              failing <- integer(0..3),
              crashing <- integer(0..2),
              resolving <- integer(0..3),
              max_sweeps <- integer(1..3)
            ) do
        # Built per execution rather than generated: shrinking holds a
        # generated value fixed while it varies the others, and a run whose
        # unresolved rows persist across executions would be swept again.
        ctx = Pipelines.build_context(Cake.Documents.Pipeline, Cake.TestPipeline, {0, 0, 0})

        failing_rows = for i <- 1..failing//1, do: insert_row(ctx, "fail-#{i}")
        crashing_rows = for i <- 1..crashing//1, do: insert_row(ctx, "crash-#{i}")
        resolving_rows = for i <- 1..resolving//1, do: insert_row(ctx, "ok-#{i}")

        retry_fn = fn
          %FailedIngest{input_identifier: "ok-" <> _} = row ->
            {:ok, _} = Cake.FailedIngests.delete_failed_ingest(row)
            {:ok, :retried}

          %FailedIngest{input_identifier: "crash-" <> _} ->
            raise "retry crashed"

          %FailedIngest{} ->
            {:error, :permanent}
        end

        started_at = DateTime.truncate(DateTime.utc_now(), :second)

        {result, _log} =
          with_log(fn -> Pipelines.sweep(ctx, retry_fn, max_sweeps: max_sweeps) end)

        unresolved = failing + crashing
        assert result == {resolving, unresolved}

        # The first pass always runs; a second runs only when the first made
        # progress and the budget allows; a third never, since the second
        # pass resolves nothing. So an unresolved row is attempted once or
        # twice, and every attempt is recorded, crash or error alike.
        attempts = if unresolved > 0 and resolving > 0 and max_sweeps >= 2, do: 2, else: 1

        for row <- failing_rows ++ crashing_rows do
          reloaded = Repo.get!(FailedIngest, row.id)
          assert reloaded.retry_count == attempts
          assert %DateTime{} = reloaded.last_retried_at
          assert DateTime.compare(reloaded.last_retried_at, started_at) in [:gt, :eq]
        end

        for row <- resolving_rows, do: refute(Repo.get(FailedIngest, row.id))
      end
    end
  end
end
