defmodule Caque.Jobs.DocumentIngestionJob do
  @moduledoc """
  This job runs the complete pipeline for downloading, parsing, embedding,
  and indexing documentation from any source that implements the
  `Caque.Documents.Pipeline` behaviour.

  ## Enqueueing

  To enqueue a job:

      DocumentIngestionJob.enqueue(%{
        source_pipeline: "Caque.Documents.Hexdocs.Pipeline",
        embedding_service: :openai,
        version: %{major: 1, minor: 18, patch: 3},
        embedding_model: "text-embedding-ada-002"
      })

  Or use the convenience function with a version tuple:

      DocumentIngestionJob.enqueue_for_version(
        Caque.Documents.Hexdocs.Pipeline,
        :openai,
        {1, 18, 3},
        "text-embedding-ada-002"
      )

  ## Adding New Document Sources

  To add a new document source:

  1. Create a module under `Caque.Documents.YourSource.Pipeline`
  2. Implement the `@behaviour Caque.Documents.Pipeline` callbacks
  3. Enqueue a job with your pipeline module

  Example with a hypothetical Clojure docs source:

      DocumentIngestionJob.enqueue_for_version(
        Caque.Documents.Clojuredocs.Pipeline,
        :openai,
        {1, 11, 1},
        "text-embedding-ada-002"
      )
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias Caque.Documents.Pipeline

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "source_pipeline" => source_pipeline_string,
      "embedding_service" => embedding_service,
      "version" => version,
      "embedding_model" => embedding_model
    } = args

    source_pipeline = String.to_existing_atom("Elixir.#{source_pipeline_string}")
    embedding_service_atom = String.to_existing_atom(embedding_service)
    version_tuple = {version["major"], version["minor"], version["patch"]}

    Logger.info(
      "Starting document ingestion with #{source_pipeline_string} " <>
        "for version #{inspect(version_tuple)} " <>
        "using #{embedding_service} with model #{embedding_model}"
    )

    case Pipeline.ingest(
           embedding_service_atom,
           source_pipeline,
           version_tuple,
           embedding_model
         ) do
      {:ok, message} ->
        Logger.info(message)
        :ok

      {:error, reason} = error ->
        Logger.error("Document ingestion failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Enqueues a new document ingestion job with the given parameters.

  ## Parameters

    * `args` - Map with keys:
      * `:source_pipeline` - Module (atom) or string name of the pipeline module
      * `:embedding_service` - Atom for the embedding service (e.g., :openai)
      * `:version` - Map with `:major`, `:minor`, and `:patch` keys
      * `:embedding_model` - String for the embedding model name

  ## Examples

      iex> DocumentIngestionJob.enqueue(%{
      ...>   source_pipeline: Caque.Documents.Hexdocs.Pipeline,
      ...>   embedding_service: :openai,
      ...>   version: %{major: 1, minor: 18, patch: 3},
      ...>   embedding_model: "text-embedding-ada-002"
      ...> })
      {:ok, %Oban.Job{}}

      iex> DocumentIngestionJob.enqueue(%{
      ...>   source_pipeline: "Caque.Documents.Hexdocs.Pipeline",
      ...>   embedding_service: :openai,
      ...>   version: %{major: 1, minor: 18, patch: 3},
      ...>   embedding_model: "text-embedding-ada-002"
      ...> })
      {:ok, %Oban.Job{}}
  """
  def enqueue(%{source_pipeline: source_pipeline} = args) when is_atom(source_pipeline) and not is_boolean(source_pipeline) do
    # Convert module atom to string and convert embedding_service atom to string
    normalized_args =
      args
      |> Map.put(:source_pipeline, module_to_string(source_pipeline))
      |> normalize_embedding_service()

    case new(normalized_args) |> Caque.Repo.insert() do
      {:ok, job} ->
        # Reload from database to ensure args are properly deserialized
        {:ok, Caque.Repo.get(Oban.Job, job.id)}

      error ->
        error
    end
  end

  def enqueue(args) when is_map(args) do
    # Normalize embedding_service if it's an atom
    normalized_args = normalize_embedding_service(args)

    case new(normalized_args) |> Caque.Repo.insert() do
      {:ok, job} ->
        # Reload from database to ensure args are properly deserialized
        {:ok, Caque.Repo.get(Oban.Job, job.id)}

      error ->
        error
    end
  end

  # Helper to convert embedding_service from atom to string if needed
  defp normalize_embedding_service(args) do
    case Map.get(args, :embedding_service) || Map.get(args, "embedding_service") do
      service when is_atom(service) and not is_nil(service) ->
        Map.put(args, :embedding_service, Atom.to_string(service))

      _ ->
        args
    end
  end

  @doc """
  Convenience function to enqueue a job with a version tuple.

  ## Parameters

    * `source_pipeline` - Module atom implementing `Caque.Documents.Pipeline` behaviour
    * `embedding_service` - Atom for the embedding service (e.g., :openai)
    * `version` - Tuple of `{major, minor, patch}` integers
    * `embedding_model` - String for the embedding model name

  ## Examples

      iex> alias Caque.Documents.Hexdocs.Pipeline, as: HexdocsPipeline
      iex> DocumentIngestionJob.enqueue_for_version(
      ...>   HexdocsPipeline,
      ...>   :openai,
      ...>   {1, 18, 3},
      ...>   "text-embedding-ada-002"
      ...> )
      {:ok, %Oban.Job{}}
  """
  def enqueue_for_version(source_pipeline, embedding_service, {major, minor, patch}, embedding_model)
      when is_atom(source_pipeline) and is_atom(embedding_service) and
             is_integer(major) and is_integer(minor) and is_integer(patch) and
             is_binary(embedding_model) do
    %{
      source_pipeline: module_to_string(source_pipeline),
      embedding_service: Atom.to_string(embedding_service),
      version: %{major: major, minor: minor, patch: patch},
      embedding_model: embedding_model
    }
    |> enqueue()
  end

  # Converts a module atom to a string without the "Elixir." prefix
  defp module_to_string(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end
end
