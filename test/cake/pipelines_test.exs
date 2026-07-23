defmodule Cake.PipelinesTest do
  @moduledoc """
  Pins down the `Cake.Pipelines.Context` contract for test-support pipelines.

  When `Cake.Documents.Pipeline.ingest/4` switched from passing a raw version
  string to passing a `%Cake.Pipelines.Context{}` struct, `Cake.TestPipeline`
  and `Cake.FailingTestPipeline` had to be updated in lockstep — interpolating
  a `%Context{}` as a string crashes with `String.Chars not implemented`.

  These tests lock the support-pipelines to the new contract so the regression
  cannot recur silently.
  """

  use Cake.DataCase, async: true

  import Mox

  alias Cake.Embeddings.Mock
  alias Cake.FailedIngests.FailedIngest
  alias Cake.FailingTestPipeline
  alias Cake.Pipelines
  alias Cake.Pipelines.Context
  alias Cake.Repo
  alias Cake.TestPipeline

  setup :verify_on_exit!

  setup do
    Application.put_env(:cake, :embeddings_module, Mock)
    on_exit(fn -> Application.delete_env(:cake, :embeddings_module) end)
    :ok
  end

  defp build_ctx(overrides) do
    Pipelines.build_context(
      Keyword.get(overrides, :behaviour, Cake.Documents.Pipeline),
      Keyword.get(overrides, :implementation, TestPipeline),
      Keyword.get(overrides, :version, {1, 18, 3}),
      Keyword.get(overrides, :opts, [])
    )
  end

  defp insert_failure(%Context{} = ctx, opts) do
    {:ok, failure} =
      Cake.FailedIngests.create_failed_ingest(%{
        pipeline_behaviour: ctx.behaviour,
        pipeline_implementation: ctx.implementation,
        step: "docs.embed",
        version: ctx.version,
        error_text: "boom",
        input_identifier: "x",
        pipeline_fatal: Keyword.fetch!(opts, :pipeline_fatal)
      })

    failure
  end

  defp stub_embeddings do
    stub(Mock, :embed, fn _service, parsed_document, _model ->
      {:ok,
       %{
         usage: %{"prompt_tokens" => 10, "total_tokens" => 10},
         struct: parsed_document.struct,
         input: parsed_document.input,
         attrs: %{embedding: List.duplicate(0.1, 1536)}
       }}
    end)
  end

  describe "Cake.Pipelines.Context" do
    test "build_context/4 with a {major, minor, patch} tuple stringifies the version" do
      ctx = Pipelines.build_context(Cake.Documents.Pipeline, TestPipeline, {1, 18, 3})

      assert %Context{
               behaviour: "Cake.Documents.Pipeline",
               implementation: "Cake.TestPipeline",
               version: "1.18.3",
               opts: []
             } = ctx
    end

    test "build_context/4 accepts an already-stringified version" do
      ctx = Pipelines.build_context(Cake.Documents.Pipeline, TestPipeline, "2.0.0", foo: :bar)

      assert ctx.version == "2.0.0"
      assert ctx.opts == [foo: :bar]
    end
  end

  describe "Cake.TestPipeline.success_message/1" do
    test "accepts a %Context{} and interpolates the version" do
      ctx = build_ctx(version: {1, 18, 3})

      message = TestPipeline.success_message(ctx)

      assert message =~ "Cake.TestPipeline"
      assert message =~ "1.18.3"
    end

    test "raises FunctionClauseError when given a raw version string" do
      # Guards against regression to the old callback signature. The bad arg is
      # passed via apply/3 so the deliberate type mismatch stays a runtime
      # concern instead of a compile-time warning.
      assert_raise FunctionClauseError, fn ->
        apply(TestPipeline, :success_message, ["1.18.3"])
      end
    end

    test "raises FunctionClauseError when given a non-Context map" do
      assert_raise FunctionClauseError, fn ->
        apply(TestPipeline, :success_message, [%{version: "1.18.3", implementation: "x"}])
      end
    end
  end

  describe "Cake.FailingTestPipeline.success_message/1" do
    test "accepts a %Context{} without crashing" do
      ctx =
        build_ctx(
          implementation: FailingTestPipeline,
          version: {1, 18, 3}
        )

      assert FailingTestPipeline.success_message(ctx) =~ "This should not be called"
    end

    test "raises FunctionClauseError when given a raw version string" do
      assert_raise FunctionClauseError, fn ->
        apply(FailingTestPipeline, :success_message, ["1.18.3"])
      end
    end
  end

  describe "Cake.Documents.Pipeline.ingest/4 cascade with TestPipeline" do
    setup do
      stub_embeddings()
      :ok
    end

    test "returns {:ok, summary} with the version message and full-success counts" do
      assert {:ok, %{message: message, indexed: indexed, failed: failed}} =
               Cake.Documents.Pipeline.ingest(
                 :openai,
                 TestPipeline,
                 {1, 18, 3},
                 "text-embedding-ada-002"
               )

      assert message =~ "Cake.TestPipeline"
      assert message =~ "1.18.3"
      # TestPipeline yields two docs; with embeddings stubbed both make it through.
      assert indexed == 2
      assert failed == 0
    end
  end

  describe "Cake.Pipelines.summarize_ingest/3" do
    test "full success (no failures) returns {:ok, summary}" do
      assert {:ok, %{message: "done", indexed: 10, failed: 0}} =
               Pipelines.summarize_ingest("done", 10, 0)
    end

    test "partial success reports the failures in the summary, not as clean success" do
      assert {:ok, summary} = Pipelines.summarize_ingest("done", 8, 2)
      assert summary.indexed == 8
      assert summary.failed == 2
    end

    test "a non-empty run where nothing made it through is an error" do
      assert {:error, {:no_items_ingested, %{indexed: 0, failed: 5}}} =
               Pipelines.summarize_ingest("done", 0, 5)
    end

    test "an empty run (nothing in, nothing failed) is a vacuous success" do
      assert {:ok, %{indexed: 0, failed: 0}} = Pipelines.summarize_ingest("done", 0, 0)
    end
  end

  describe "Cake.Pipelines.count_failures/1" do
    test "counts only non-fatal failures matching the run's identity" do
      ctx = build_ctx(version: {1, 18, 3})

      # Two non-fatal item failures for this run's identity.
      for _ <- 1..2, do: insert_failure(ctx, pipeline_fatal: false)
      # A fatal failure for the same identity must be excluded.
      insert_failure(ctx, pipeline_fatal: true)
      # A non-fatal failure for a different version must be excluded.
      other = build_ctx(version: {9, 9, 9})
      insert_failure(other, pipeline_fatal: false)

      assert Pipelines.count_failures(ctx) == 2
    end
  end

  describe "Cake.Documents.Pipeline.ingest/4 with item-level embed failures" do
    # Partial-success (some in, some out) is pinned deterministically by the
    # `summarize_ingest/3` unit tests above. Here we exercise the full stream
    # wiring on the deterministic extreme: every item fails, so embed errors
    # must be dropped + counted (not leaked through as phantom successes).
    test "total failure: every embedding fails, so nothing is ingested -> {:error, _}" do
      stub(Mock, :embed, fn _service, _doc, _model -> {:error, :embed_unavailable} end)

      assert {:error, {:no_items_ingested, %{indexed: 0, failed: 2}}} =
               Cake.Documents.Pipeline.ingest(
                 :openai,
                 TestPipeline,
                 {4, 4, 4},
                 "text-embedding-ada-002"
               )
    end
  end

  describe "Cake.Documents.Pipeline.ingest/4 cascade with FailingTestPipeline" do
    test "routes the {:error, step, reason} tuple through handle_ingest_error/2" do
      result =
        Cake.Documents.Pipeline.ingest(
          :openai,
          FailingTestPipeline,
          {1, 18, 3},
          "text-embedding-ada-002"
        )

      assert {:error, {:download, "Network error"}} = result
    end

    test "persists a pipeline-fatal FailedIngest row tagged with the Context fields" do
      _ =
        Cake.Documents.Pipeline.ingest(
          :openai,
          FailingTestPipeline,
          {1, 18, 3},
          "text-embedding-ada-002"
        )

      failures = Repo.all(FailedIngest)

      assert [failure | _] = failures
      assert failure.pipeline_behaviour == "Cake.Documents.Pipeline"
      assert failure.pipeline_implementation == "Cake.FailingTestPipeline"
      assert failure.pipeline_fatal == true
      assert failure.step == "download"
      assert failure.version == "1.18.3"
    end
  end

  describe "detuple_with_logging/3" do
    test "passes through {:ok, value} tuples, unwrapped" do
      ctx = build_ctx([])
      stream = Stream.map([{:ok, :a}, {:ok, :b}], & &1)

      result = Enum.to_list(Pipelines.detuple_with_logging(stream, "test.step", ctx))

      assert result == [:a, :b]
    end

    test "filters out {:error, reason} tuples and persists failures" do
      ctx = build_ctx(version: {7, 7, 7})
      stream = Stream.map([{:ok, :good}, {:error, {"id1", "boom"}}], & &1)

      result = Enum.to_list(Pipelines.detuple_with_logging(stream, "test.step", ctx))

      assert result == [:good]

      failures = Cake.FailedIngests.list_failed_ingests()
      assert Enum.any?(failures, &(&1.step == "test.step" && &1.input_identifier == "id1"))
    end

    test "filters out unexpected non-tuple values and persists failures" do
      ctx = build_ctx(version: {8, 8, 8})
      stream = Stream.map([{:ok, :good}, :bare_atom], & &1)

      result = Enum.to_list(Pipelines.detuple_with_logging(stream, "test.step", ctx))

      assert result == [:good]

      failures = Cake.FailedIngests.list_failed_ingests()
      assert Enum.any?(failures, &(&1.step == "test.step"))
    end
  end

  describe "log_and_persist_failure/3" do
    test "persists a FailedIngest with the step name and error info" do
      ctx = build_ctx(version: {6, 6, 6})

      {:ok, failure} =
        Pipelines.log_and_persist_failure(ctx, "manual.step", {"doc-42", "timeout"})

      assert failure.step == "manual.step"
      assert failure.input_identifier == "doc-42"
      assert failure.error_text == "timeout"
    end
  end

  describe "handle_ingest_error/2" do
    test "handles {:error, step, error} with atom step" do
      ctx = build_ctx(version: {5, 5, 5})

      result = Pipelines.handle_ingest_error({:error, :download, "git failed"}, ctx)

      assert {:error, {:download, "git failed"}} = result
    end

    test "handles {:error, error} without step" do
      ctx = build_ctx(version: {5, 5, 5})

      assert {:error, "network timeout"} =
               Pipelines.handle_ingest_error({:error, "network timeout"}, ctx)

      [failure] =
        Repo.all(
          from f in FailedIngest,
            where: f.pipeline_behaviour == ^ctx.behaviour,
            where: f.version == ^ctx.version,
            where: f.pipeline_fatal == true
        )

      assert failure.step == "ingest"
    end
  end

  describe "sweep/5" do
    test "returns {0, 0} when no failures exist" do
      assert {0, 0} =
               Pipelines.sweep(
                 "Cake.Test.Pipeline",
                 "Cake.TestImpl",
                 "1.0.0",
                 fn _ -> {:ok, :retried} end
               )
    end

    test "retries failures and counts resolved" do
      ctx = build_ctx(version: {3, 3, 3})
      insert_failure(ctx, pipeline_fatal: false)

      {resolved, remaining} =
        Pipelines.sweep(
          ctx.behaviour,
          ctx.implementation,
          ctx.version,
          fn failure ->
            Cake.FailedIngests.delete_failed_ingest(failure)
            {:ok, :retried}
          end
        )

      assert resolved == 1
      assert remaining == 0
    end

    test "stops early when no progress is made" do
      ctx = build_ctx(version: {2, 2, 2})
      insert_failure(ctx, pipeline_fatal: false)

      {resolved, remaining} =
        Pipelines.sweep(
          ctx.behaviour,
          ctx.implementation,
          ctx.version,
          fn _failure -> {:error, :permanent} end
        )

      assert resolved == 0
      assert remaining == 1
    end

    test "respects max_sweeps option" do
      ctx = build_ctx(version: {1, 1, 1})
      insert_failure(ctx, pipeline_fatal: false)

      {resolved, remaining} =
        Pipelines.sweep(
          ctx.behaviour,
          ctx.implementation,
          ctx.version,
          fn _failure -> {:error, :permanent} end,
          max_sweeps: 1
        )

      assert resolved == 0
      assert remaining == 1
    end
  end
end
