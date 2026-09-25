defmodule Cake.Jobs.DocumentIngestionJobIntegrationTest do
  @moduledoc """
  `Cake.Jobs.DocumentIngestionJob` wired to the real Hexdocs pipeline
  (#248): a job enqueued through `enqueue_for_version/4` and drained runs
  `Cake.Documents.Pipeline.ingest/4` for real — a `git clone` of the tagged
  release, `Hexdoc` and `ParsedDocument` rows in Postgres, documents in the
  `docs` collection of a real OpenSearch node — from nothing but its
  serialized args. The five pre-existing `:integration` Oban tests drive
  `Cake.TestPipeline`; this is the only place the job meets the real one.

  Tagged `:network` instead of `:integration` (the clone), like
  `Cake.Documents.Hexdocs.PipelineIntegrationTest`: runs only with
  `mix test --only integration --include network`. `async: false`: the
  pipeline indexes into the GDS's fixed collection, and Oban's queue is
  shared.
  """

  use Cake.SearchIntegrationCase, async: false, network: true

  import Cake.IngestIntegrationHelpers
  import Cake.ObanCase, only: [all_enqueued_jobs: 1, drain_jobs: 1]
  import ExUnit.CaptureIO, only: [with_io: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Mox

  alias Cake.Documents.Hexdocs
  alias Cake.Documents.ParsedDocument
  alias Cake.Documents.ParsedDocuments
  alias Cake.FailedIngests.FailedIngest
  alias Cake.Jobs.DocumentIngestionJob
  alias Cake.Repo

  @version {1, 0, 0}
  @version_string "1.0.0"

  setup :verify_on_exit!

  setup do
    ensure_collection!(ParsedDocument)
    :ok
  end

  defp ids(structs), do: Enum.map(structs, & &1.id)

  test "a drained job runs the real Hexdocs pipeline from its args: raw rows, parsed rows, real index" do
    stub_embeddings()
    model = embedding_model()

    assert {:ok, %Oban.Job{args: args}} =
             DocumentIngestionJob.enqueue_for_version(Hexdocs.Pipeline, :openai, @version, model)

    assert args == %{
             "source_pipeline" => "Cake.Documents.Hexdocs.Pipeline",
             "embedding_service" => "openai",
             "version" => %{"major" => 1, "minor" => 0, "patch" => 0},
             "embedding_model" => model
           }

    assert [%Oban.Job{state: "available", worker: "Cake.Jobs.DocumentIngestionJob"}] =
             all_enqueued_jobs(:default)

    {{drained, _log}, _parser_warnings} =
      with_io(:stderr, fn -> with_log(fn -> drain_jobs(:default) end) end)

    assert %{success: 1, failure: 0} = drained
    assert [%Oban.Job{state: "completed"}] = Repo.all(Oban.Job)

    assert Hexdocs.hexdocs_by_version(@version_string) != []
    docs = ParsedDocuments.by_source_and_version("hexdocs", @version_string)
    assert docs != []
    assert Enum.all?(docs, &(&1.embedding == deterministic_embedding(embed_input(&1))))
    assert Enum.sort(indexed_ids!(ParsedDocument)) == Enum.sort(ids(docs))
    assert Repo.all(FailedIngest) == []
  end

  test "a job whose download fails (no such tag) fails the attempt and persists the pipeline-fatal row" do
    assert {:ok, %Oban.Job{}} =
             DocumentIngestionJob.enqueue_for_version(
               Hexdocs.Pipeline,
               :openai,
               {0, 0, 0},
               embedding_model()
             )

    {{drained, log}, _git_stderr} =
      with_io(:stderr, fn -> with_log(fn -> drain_jobs(:default) end) end)

    assert %{success: 0, failure: 1} = drained
    assert log =~ "Document ingestion failed"
    assert log =~ "git clone failed"

    assert [%Oban.Job{state: "retryable", attempt: 1, max_attempts: 3, errors: [error]}] =
             Repo.all(Oban.Job)

    assert error["error"] =~ "git clone failed"

    assert [%FailedIngest{pipeline_fatal: true, step: "download"} = failure] =
             Repo.all(FailedIngest)

    assert failure.pipeline_behaviour == "Cake.Documents.Pipeline"
    assert failure.pipeline_implementation == "Cake.Documents.Hexdocs.Pipeline"
    assert failure.version == "0.0.0"
    assert failure.error_text =~ "git clone failed"

    assert Hexdocs.hexdocs_by_version("0.0.0") == []
    assert indexed_ids!(ParsedDocument) == []
  end
end
