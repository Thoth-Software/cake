defmodule Cake.Documents.PipelineTest do
  @moduledoc """
  Pins the retry contract of the documents orchestrator: `retry/4` answers
  every `FailedIngest` row a run can record with a result tuple, so
  `Pipelines.sweep/3` (which calls it with no rescue) never crashes on a row
  it cannot retry (#301).
  """

  use Cake.DataCase, async: true

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

  # The raw row a parse failure is retried from: the module name is what
  # Hexdocs.Pipeline records as the failure's input_identifier.
  defp insert_hexdoc!(ctx, module, content) do
    {:ok, hexdoc} =
      Hexdocs.create_hexdoc(%{
        module: module,
        version: ctx.version,
        url: "https://hexdocs.pm/elixir/#{module}",
        content: content
      })

    hexdoc
  end

  defp stub_embeddings do
    stub(Cake.Embeddings.Mock, :embed, fn _service, %{struct: struct, input: input}, _model ->
      {:ok, %{struct: struct, input: input, attrs: %{embedding: List.duplicate(0.1, 1536)}}}
    end)
  end

  describe "retry/4 on a docs.parse row" do
    test "re-parses the stored Hexdoc, persists, embeds and indexes it, and resolves the row" do
      ctx = build_ctx()
      stub_embeddings()

      insert_hexdoc!(ctx, "kernel.ex", """
      defmodule Kernel do
        @doc "Adds two numbers."
        def add(a, b), do: a + b
      end
      """)

      failure = insert_failure(ctx, "docs.parse", %{input_identifier: "kernel.ex"})

      assert {:ok, :retried} = retry(failure)

      assert [%ParsedDocument{package: "kernel.ex", title: "add/2", embedding: [_ | _]} = doc] =
               Repo.all(ParsedDocument)

      assert doc.text =~ "Adds two numbers."
      assert doc.version == ctx.version
      assert Repo.all(FailedIngest) == []
    end

    test "returns an error and leaves the row when no Hexdoc holds that module" do
      failure = insert_failure(build_ctx(), "docs.parse", %{input_identifier: "kernel.ex"})

      assert {:error, {:raw_doc_not_found, "kernel.ex"}} = retry(failure)
      assert [%FailedIngest{step: "docs.parse"}] = Repo.all(FailedIngest)
      assert Repo.all(ParsedDocument) == []
    end

    test "returns an error and leaves the row for the \"unknown\" identifier" do
      # hexdoc_identifier/1 records "unknown" when the failing value had no
      # module to name; there is no raw row to resume from.
      failure = insert_failure(build_ctx(), "docs.parse", %{input_identifier: "unknown"})

      assert {:error, {:raw_doc_not_found, "unknown"}} = retry(failure)
      assert [%FailedIngest{step: "docs.parse"}] = Repo.all(FailedIngest)
    end
  end

  describe "retry/4 on a step it does not handle" do
    test "returns {:error, {:unsupported_step, step}} for a docs.persist_raw row" do
      failure = insert_failure(build_ctx(), "docs.persist_raw")

      assert {:error, {:unsupported_step, "docs.persist_raw"}} = retry(failure)
      assert [%FailedIngest{step: "docs.persist_raw"}] = Repo.all(FailedIngest)
    end

    test "a sweep over a run holding an unresolvable docs.parse row and a docs.persist_raw row leaves both remaining" do
      ctx = build_ctx()
      insert_failure(ctx, "docs.parse")
      insert_failure(ctx, "docs.persist_raw")

      # The same retry_fn ingest_with_sweep/5 hands to the sweep. The parse
      # row names a module no Hexdoc holds, so it cannot be re-parsed.
      capture_log(fn -> assert {0, 2} = Pipelines.sweep(ctx, &retry/1) end)

      assert ["docs.parse", "docs.persist_raw"] =
               FailedIngest |> Repo.all() |> Enum.map(& &1.step) |> Enum.sort()
    end
  end
end
