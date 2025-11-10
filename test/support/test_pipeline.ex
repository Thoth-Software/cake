defmodule Caque.TestPipeline do
  @moduledoc """
  Mock pipeline module for testing DocumentIngestionJob.

  Implements the Caque.Documents.Pipeline behaviour with test-friendly
  implementations that don't require external dependencies or side effects.
  """

  @behaviour Caque.Documents.Pipeline

  @impl true
  def download(_version) do
    {:ok, ["test_file_1.html", "test_file_2.html"]}
  end

  @impl true
  def persist_raw_docs(file_paths, _version) do
    # Return a stream of file paths to simulate persistence
    Stream.map(file_paths, fn path -> %{file: path, persisted: true} end)
  end

  @impl true
  def parse(raw_docs_stream) do
    # Return a stream of mock parsed documents
    # Takes the raw_docs_stream and transforms it
    raw_docs_stream
    |> Stream.flat_map(fn _raw_doc ->
      [
        %{
          title: "Test Doc",
          text: "Test content",
          url: "https://example.com/doc",
          source: source(),
          version: "1.0.0",
          package: "TestPackage",
          language: "Elixir",
          core: true
        }
      ]
    end)
  end

  @impl true
  def source do
    "TestPipeline"
  end

  @impl true
  def success_message(version) do
    "Successfully ingested test documents for version #{version}"
  end
end

defmodule Caque.FailingTestPipeline do
  @moduledoc """
  Mock pipeline that fails during download for testing error cases.
  """

  @behaviour Caque.Documents.Pipeline

  @impl true
  def download(_version) do
    {:error, "Network error"}
  end

  @impl true
  def persist_raw_docs(_file_paths, _version) do
    Stream.map([], fn _ -> nil end)
  end

  @impl true
  def parse(raw_docs_stream) do
    raw_docs_stream
  end

  @impl true
  def source do
    "FailingTestPipeline"
  end

  @impl true
  def success_message(version) do
    "This should not be called - version #{version}"
  end
end
