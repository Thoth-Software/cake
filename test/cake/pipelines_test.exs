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
      # Guards against regression to the old callback signature.
      assert_raise FunctionClauseError, fn ->
        TestPipeline.success_message("1.18.3")
      end
    end

    test "raises FunctionClauseError when given a non-Context map" do
      assert_raise FunctionClauseError, fn ->
        TestPipeline.success_message(%{version: "1.18.3", implementation: "x"})
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

      assert is_binary(FailingTestPipeline.success_message(ctx))
    end

    test "raises FunctionClauseError when given a raw version string" do
      assert_raise FunctionClauseError, fn ->
        FailingTestPipeline.success_message("1.18.3")
      end
    end
  end

  describe "Cake.Documents.Pipeline.ingest/4 cascade with TestPipeline" do
    setup do
      stub_embeddings()
      :ok
    end

    test "returns {:ok, message} containing the version (no String.Chars crash)" do
      assert {:ok, message} =
               Cake.Documents.Pipeline.ingest(
                 :openai,
                 TestPipeline,
                 {1, 18, 3},
                 "text-embedding-ada-002"
               )

      assert message =~ "Cake.TestPipeline"
      assert message =~ "1.18.3"
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
end
