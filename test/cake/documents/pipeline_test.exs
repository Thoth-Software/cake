defmodule Cake.Documents.PipelineTest do
  @moduledoc """
  Pins two contracts of the documents orchestrator. `retry/4` answers every
  `FailedIngest` row a run can record with a result tuple, so
  `Pipelines.sweep/3` (which calls it with no rescue) never crashes on a row
  it cannot retry (#301). And a crash inside a `batch_embed/5` task is an
  item-level failure, recorded with the document's id, never the end of the
  run (#273).
  """

  use Cake.DataCase, async: true

  import Cake.ParsedDocumentFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cake.Documents.Hexdocs
  alias Cake.Documents.ParsedDocument
  alias Cake.Documents.Pipeline
  alias Cake.FailedIngests.FailedIngest
  alias Cake.Pipelines
  alias Cake.Pipelines.Context

  @embedding_model "text-embedding-ada-002"

  setup :verify_on_exit!

  defp build_ctx do
    Pipelines.build_context(Pipeline, Hexdocs.Pipeline, {1, 0, 0})
  end

  defp insert_failure(%Context{} = ctx, step, overrides \\ %{}) do
    {:ok, failure} =
      %{
        run_id: ctx.run_id,
        pipeline_behaviour: ctx.behaviour,
        pipeline_implementation: ctx.implementation,
        step: step,
        version: ctx.version,
        error_text: "boom",
        input_identifier: "Kernel.ex@1.0.0",
        pipeline_fatal: false
      }
      |> Map.merge(overrides)
      |> Cake.FailedIngests.create_failed_ingest()

    failure
  end

  defp retry(failure), do: Pipeline.retry(failure, Hexdocs.Pipeline, :openai, @embedding_model)

  defp batch_embed(docs, ctx),
    do: Pipeline.batch_embed(docs, :openai, Hexdocs.Pipeline, @embedding_model, ctx)

  describe "batch_embed/5 when a task crashes" do
    test "records a document whose embed task crashes under docs.embed and embeds the rest" do
      crashing = parsed_documents_fixture(%{title: "Crashing"})
      fine = parsed_documents_fixture(%{title: "Fine"})
      fine_id = fine.id
      ctx = build_ctx()

      expect(Cake.Embeddings.Mock, :embed, 2, fn :openai,
                                                 %{input: input, struct: doc},
                                                 @embedding_model ->
        if input =~ "Crashing" do
          raise "malformed embeddings body"
        else
          {:ok, %{struct: doc, attrs: %{embedding: [0.1, 0.2, 0.3]}}}
        end
      end)

      capture_log(fn ->
        assert [%ParsedDocument{id: ^fine_id, embedding: [0.1, 0.2, 0.3]}] =
                 Enum.to_list(batch_embed([crashing, fine], ctx))
      end)

      assert [%FailedIngest{} = failure] = Repo.all(FailedIngest)
      assert failure.step == "docs.embed"
      assert failure.input_identifier == crashing.id
      assert failure.error_text =~ "RuntimeError"
      assert failure.error_text =~ "malformed embeddings body"
    end

    test "records a document whose embedding-persist task crashes under docs.embed_persist" do
      doc = parsed_documents_fixture(%{title: "Bad attrs"})
      ctx = build_ctx()

      # A provider answer the persist step cannot cast: the changeset raises
      # inside the persist task rather than returning an error tuple.
      expect(Cake.Embeddings.Mock, :embed, fn :openai, %{struct: struct}, @embedding_model ->
        {:ok, %{struct: struct, attrs: :not_a_map}}
      end)

      capture_log(fn -> assert [] = Enum.to_list(batch_embed([doc], ctx)) end)

      assert [%FailedIngest{} = failure] = Repo.all(FailedIngest)
      assert failure.step == "docs.embed_persist"
      assert failure.input_identifier == doc.id
      assert failure.error_text =~ "Ecto.CastError"
    end
  end

  describe "retry/4 on a row with no input_identifier" do
    test "rejects a docs.persist row with an error tuple instead of crashing" do
      # A "docs.persist" row recorded from {:error, {:task_exit, _}} carries no
      # identifier, so there is no raw doc to re-parse from.
      failure = insert_failure(build_ctx(), "docs.persist", %{input_identifier: nil})

      assert {:error, {:no_input_identifier, failure.id}} == retry(failure)
      assert [%FailedIngest{input_identifier: nil}] = Repo.all(FailedIngest)
    end

    test "rejects a docs.embed row with an error tuple instead of crashing" do
      # batch_embed/5 records a provider error as {nil, reason}: no document
      # id to resume from.
      failure = insert_failure(build_ctx(), "docs.embed", %{input_identifier: nil})

      assert {:error, {:no_input_identifier, failure.id}} == retry(failure)
      assert [%FailedIngest{input_identifier: nil}] = Repo.all(FailedIngest)
    end

    test "rejects a docs.embed_persist row with an error tuple instead of crashing" do
      # A killed embed-persistence task is recorded as {nil, reason} too.
      failure = insert_failure(build_ctx(), "docs.embed_persist", %{input_identifier: nil})

      assert {:error, {:no_input_identifier, failure.id}} == retry(failure)
      assert [%FailedIngest{input_identifier: nil}] = Repo.all(FailedIngest)
    end
  end

  describe "retry/4 on a step it does not handle" do
    test "returns {:error, {:unsupported_step, step}} for a docs.parse row" do
      failure = insert_failure(build_ctx(), "docs.parse")

      assert {:error, {:unsupported_step, "docs.parse"}} = retry(failure)
      assert [%FailedIngest{step: "docs.parse"}] = Repo.all(FailedIngest)
    end

    test "returns {:error, {:unsupported_step, step}} for a docs.persist_raw row" do
      failure = insert_failure(build_ctx(), "docs.persist_raw")

      assert {:error, {:unsupported_step, "docs.persist_raw"}} = retry(failure)
      assert [%FailedIngest{step: "docs.persist_raw"}] = Repo.all(FailedIngest)
    end

    test "a sweep over a run holding docs.parse and docs.persist_raw rows leaves them remaining" do
      ctx = build_ctx()
      insert_failure(ctx, "docs.parse")
      insert_failure(ctx, "docs.persist_raw")

      # The same retry_fn ingest_with_sweep/5 hands to the sweep.
      capture_log(fn -> assert {0, 2} = Pipelines.sweep(ctx, &retry/1) end)

      assert ["docs.parse", "docs.persist_raw"] =
               FailedIngest |> Repo.all() |> Enum.map(& &1.step) |> Enum.sort()
    end
  end
end
