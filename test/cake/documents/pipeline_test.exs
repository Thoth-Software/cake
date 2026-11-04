defmodule Cake.Documents.PipelineTest do
  @moduledoc """
  Pins two contracts of the documents orchestrator. `retry/4` answers every
  `FailedIngest` row a run can record with a result tuple, so
  `Pipelines.sweep/3` (which calls it with no rescue) never crashes on a row
  it cannot retry (#301). And a crash inside a `batch_embed/5` task is an
  item-level failure, recorded with the document's id, never the end of the
  run, as is a persist task that exits, recorded under the doc's
  `package@version` (#273). And every embedded document records the model
  that produced its vector, while a retry never writes a vector under a
  model other than the one its corpus (same `source` and `version`) was
  embedded under (#284).
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

  describe "unwrap_persisted_doc_result/1" do
    test "passes a persist task's own result through" do
      assert {:ok, :doc} = Pipeline.unwrap_persisted_doc_result({:ok, {:ok, :doc}})

      assert {:error, {"Kernel.ex@1.0.0", "boom"}} =
               Pipeline.unwrap_persisted_doc_result({:ok, {:error, {"Kernel.ex@1.0.0", "boom"}}})
    end

    test "records a persist task that exited under the doc's package@version" do
      attrs = %{package: "Kernel.ex", version: "1.0.0", title: "Kernel", text: "docs"}

      assert {:error, {"Kernel.ex@1.0.0", ":killed"}} =
               Pipeline.unwrap_persisted_doc_result({:exit, {attrs, :killed}})
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
      # The stage records every row with the document's id today; a row
      # without one (recorded before it did) still gets an answer.
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

  describe "embedding_model on every embedded document (#284)" do
    defp corpus_doc(title, overrides \\ %{}) do
      parsed_documents_fixture(
        Map.merge(%{title: title, source: "hexdocs", version: "1.0.0"}, overrides)
      )
    end

    defp embed_ok do
      expect(Cake.Embeddings.Mock, :embed, fn :openai, %{struct: doc}, @embedding_model ->
        {:ok, %{struct: doc, attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)
    end

    defp embedded_under!(doc, model) do
      {:ok, doc} =
        Cake.Documents.ParsedDocuments.update_parsed_document(doc, %{
          embedding: [0.4, 0.5, 0.6],
          embedding_model: model
        })

      doc
    end

    test "batch_embed/5 records the model with each vector" do
      doc = corpus_doc("Enum")
      embed_ok()

      assert [embedded] = Enum.to_list(batch_embed([doc], build_ctx()))
      assert {embedded.embedding, embedded.embedding_model} == {[0.1, 0.2, 0.3], @embedding_model}

      stored = Repo.get!(ParsedDocument, doc.id)
      assert {stored.embedding, stored.embedding_model} == {[0.1, 0.2, 0.3], @embedding_model}
    end

    test "retry/4 of a docs.embed row re-embeds under the corpus's model and records it" do
      _sibling = "Map" |> corpus_doc() |> embedded_under!(@embedding_model)
      doc = corpus_doc("Enum")
      failure = insert_failure(build_ctx(), "docs.embed", %{input_identifier: doc.id})
      embed_ok()

      assert {:ok, :retried} = retry(failure)

      stored = Repo.get!(ParsedDocument, doc.id)
      assert {stored.embedding, stored.embedding_model} == {[0.1, 0.2, 0.3], @embedding_model}
      assert Repo.all(FailedIngest) == []
    end

    test "retry/4 refuses a model other than the corpus's, embedding nothing" do
      # No Mox expectation: any embed call fails the test.
      _sibling = "Map" |> corpus_doc() |> embedded_under!("old-model")
      doc = corpus_doc("Enum")
      failure = insert_failure(build_ctx(), "docs.embed", %{input_identifier: doc.id})

      assert {:error, {:embedding_model_mismatch, doc_id, ["old-model"], @embedding_model}} =
               retry(failure)

      assert doc_id == doc.id
      assert Repo.get!(ParsedDocument, doc.id).embedding_model == nil
      assert [%FailedIngest{}] = Repo.all(FailedIngest)
    end

    test "retry/4 refuses a model other than the document's own stored one" do
      doc = "Enum" |> corpus_doc() |> embedded_under!("old-model")
      failure = insert_failure(build_ctx(), "search_backend.index", %{input_identifier: doc.id})

      assert {:error, {:embedding_model_mismatch, _doc_id, ["old-model"], @embedding_model}} =
               retry(failure)

      assert Repo.get!(ParsedDocument, doc.id).embedding_model == "old-model"
    end

    test "documents of another source version do not count as the corpus" do
      _other_version = "Map" |> corpus_doc(%{version: "0.9.0"}) |> embedded_under!("old-model")
      doc = corpus_doc("Enum")
      failure = insert_failure(build_ctx(), "docs.embed", %{input_identifier: doc.id})
      embed_ok()

      assert {:ok, :retried} = retry(failure)
      assert Repo.get!(ParsedDocument, doc.id).embedding_model == @embedding_model
    end
  end
end
