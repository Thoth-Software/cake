defmodule Cake.TestPipeline do
  @moduledoc """
  Mock pipeline module for testing DocumentIngestionJob.

  Implements the Cake.Documents.Pipeline behaviour with test-friendly
  implementations that don't require external dependencies or side effects.
  """

  @behaviour Cake.Documents.Pipeline

  @impl Cake.Documents.Pipeline
  def download(_version) do
    {:ok, ["test_file_1.html", "test_file_2.html"]}
  end

  @impl Cake.Documents.Pipeline
  def persist_raw_docs(file_paths, _version) do
    # Return a stream of file paths to simulate persistence
    Stream.map(file_paths, fn path -> %{file: path, persisted: true} end)
  end

  @impl Cake.Documents.Pipeline
  def parse(raw_docs_stream, _ctx) do
    raw_docs_stream
    |> Stream.with_index()
    |> Stream.flat_map(fn {_raw_doc, idx} ->
      [
        %{
          title: "Test Doc #{idx}",
          text: "Test content #{idx}",
          url: "https://example.com/doc/#{idx}",
          source: source(),
          version: "1.0.0",
          package: "TestPackage",
          language: "Elixir",
          core: true
        }
      ]
    end)
  end

  @impl Cake.Documents.Pipeline
  def source do
    "TestPipeline"
  end

  @impl Cake.Documents.Pipeline
  def success_message(%Cake.Pipelines.Context{implementation: impl, version: version}) do
    "Successfully ingested test documents (#{impl}) for version #{version}"
  end
end

defmodule Cake.FailingTestPipeline do
  @moduledoc """
  Mock pipeline that fails during download for testing error cases.
  """

  @behaviour Cake.Documents.Pipeline

  @impl Cake.Documents.Pipeline
  def download(_version) do
    {:error, :download, "Network error"}
  end

  @impl Cake.Documents.Pipeline
  def persist_raw_docs(_file_paths, _version) do
    Stream.map([], fn _ -> nil end)
  end

  @impl Cake.Documents.Pipeline
  def parse(raw_docs_stream, _ctx) do
    raw_docs_stream
  end

  @impl Cake.Documents.Pipeline
  def source do
    "FailingTestPipeline"
  end

  @impl Cake.Documents.Pipeline
  def success_message(%Cake.Pipelines.Context{implementation: impl}) do
    "This should not be called - #{impl}"
  end
end
