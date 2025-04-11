defmodule Caque.Documents.Pipeline do
  @moduledoc """
  Behaviour for document ingestion pipelines. These are understood to be programming language documentation with the structure that such docs normally have, e.g. Clojuredocs, Hexdocs, etc.

  Modules implementing this pipeline live under the Caque.Documents namespace, with Caque.Documents.DocumentSource being the name of each source_pipeline module. Modules are abstractions over data types; in this case, the data type is "documents from a particular documente want to do more-or-less the same thing with all our technical documents: turn them into embeddings and store 'em in Opensearch with some metadata. However, each body of documents has unique HTML to parse and may be acquired uniquely. So we have a situation where we want to take a lot of heterogeneous data and feed it all through the same pipeline and get the same result. The natural move here is to use a behaviour to abstract away those details and expose callbacks for all the things that have to be made bespoke for each doc source. Breaking these tasks apart and exposing each one as a public function allows for greater observability and easier debugging. Yes, we certainly COULD write a lot of this as ponderous hundred-liners, but I prefer things to be more modular.

  (Functional programming proverb: The Master had a chain made, with hundreds of smaller links rather than a few dozen big ones. When asked why, he said, "When it breaks, I will know precisely where.")

  The pipeline runs:

  version                   # For core modules, this is the language version. Otherwise, it's the package version.
  |> download()           
  |> persist_raw_docs(file_paths)   # Save the raw data, most likely HTML. This is our source of truth.

  version
  |> parse()                # parse/1 is a callback and is therefore aware of which language it's fetching for; it just needs the version.
  |> persist_parsed_docs() # no need for a callback because parsed_docs is generic

  version
  |> batch_embed()
  |> save_embeddings(version)

  Each transformation step is decoupled from storage. This enables streaming, chunking, observability, and intermediate debugging.

  default embedding model, right now, is "text-embedding-ada-002"
  Caque.Documents.Pipeline.ingest(:openai, Caque.Documents.Hexdocs.Pipeline, {1,18,3}, "text-embedding-ada-002")
  """

  alias Caque.Documents.ParsedDocuments
  require Logger

  @cluster Caque.Documents.Cluster
  @index "docs"

  @type version :: {integer(), integer(), integer()}

  @callback download(String.t()) :: {:ok, [String.t()]} | {:error, :download, any()}
  @callback persist_raw_docs([String.t()], String.t()) :: :ok | {:error, :persist_raw_docs, any()}
  @callback parse(String.t()) :: {:ok, Enumerable.t()} | {:error, :parse, any()}
  @callback source() :: String.t()
  @callback success_message(String.t()) :: String.t()

  @spec ingest(atom(), atom(), version(), String.t()) :: {:ok, String.t()} | {:error, any()}
  def ingest(embedding_service, source_pipeline, {major, minor, patch}, embedding_model) do
    version = Enum.join([major, minor, patch], ".")

    # :ok <- add_to_opensearch(source_pipeline.source(), version)
    with {:ok, file_paths} <- source_pipeline.download(version),
         :ok <- source_pipeline.persist_raw_docs(file_paths, version),
         parsed_docs_stream <- source_pipeline.parse(version),
         persisted_parsed_docs_stream <- persist_parsed_docs(parsed_docs_stream) do
         # :ok <- batch_embed(embedding_service, source_pipeline, embedding_model, version) do
      {:ok, source_pipeline.success_message(version)}
    else
      error -> error
     end
  end

  def add_to_opensearch(source, version) do
    ParsedDocuments.by_source_and_version(source, version)
    |> Task.async_stream(
      &Snap.Document.create(@cluster, @index, &1, &1.id),
      max_concurrency: 5,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.each(fn return ->
      case return do
        {:ok, %{"_id" => id}} -> Logger.info("Document #{id} created in #{@index}")
        _ -> Logger.warning("Failed to insert document")
      end
    end)
  end

  # Caque.Documents.Pipeline.batch_embed(:openai, Caque.Documents.Hexdocs.Pipeline, "text-embedding-ada-002", "1.18.3")
  def batch_embed(embedding_service, source_pipeline, embedding_model, version) do
    source_pipeline.source()
    |> ParsedDocuments.by_source_and_version(version)
    |> Task.async_stream(
      &Caque.Embeddings.embed(embedding_service, &1, embedding_model),
      max_concurrency: 5,
      timeout: 5_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.each(&handle_response/1)
  end

  defp handle_response({:exit, {input, reason}}) do
    Logger.warning("EMBEDDING FAILED\n\nReason: #{reason}\n\n input: #{input.title}")
  end

  defp handle_response({_, {:error, error}}), do: Logger.warning(error)

  defp handle_response({_, {_, %{parsed_document: parsed_document}}}) do
    ParsedDocuments.update_parsed_doc(parsed_document)
  end

  defp persist_parsed_docs(parsed_doc_stream) do
    Task.async_stream(parsed_doc_stream, &ParsedDocuments.create_parsed_docs!/1)
  end
end
