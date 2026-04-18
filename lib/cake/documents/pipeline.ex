defmodule Cake.Documents.Pipeline do
  @moduledoc """
  Behaviour for document ingestion pipelines. These are understood to be programming language documentation with the structure that such docs normally have, e.g. Clojuredocs, Hexdocs, etc.

  Modules implementing this pipeline live under the Cake.Documents namespace, with Cake.Documents.DocumentSource being the name of each source_pipeline module. Modules are abstractions over data types; in this case, the data type is "documents from a particular documente want to do more-or-less the same thing with all our technical documents: turn them into embeddings and store 'em in Opensearch with some metadata. However, each body of documents has unique HTML to parse and may be acquired uniquely. So we have a situation where we want to take a lot of heterogeneous data and feed it all through the same pipeline and get the same result. The natural move here is to use a behaviour to abstract away those details and expose callbacks for all the things that have to be made bespoke for each doc source. Breaking these tasks apart and exposing each one as a public function allows for greater observability and easier debugging. Yes, we certainly COULD write a lot of this as ponderous hundred-liners, but I prefer things to be more modular.

  (Functional programming analect: The Master had a chain made, with hundreds of smaller links rather than a few dozen big ones. When asked why, he said, "When it breaks, I will know precisely where.")

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
  Cake.Documents.Pipeline.ingest(:openai, Cake.Documents.Hexdocs.Pipeline, {1,18,3}, "text-embedding-ada-002")
  """

  alias Cake.Documents.ParsedDocument
  alias Cake.Documents.ParsedDocuments
  alias Cake.Pipelines
  alias Cake.Pipelines.Context
  alias Cake.Repo
  require Logger

  @cluster Cake.Documents.Cluster
  @index "docs"

  @type version :: {integer(), integer(), integer()}

  @callback download(Context.t()) :: {:ok, [String.t()]} | {:error, :download, any()}
  @callback persist_raw_docs([String.t()], Context.t()) :: Enumerable.t()
  @callback parse(Enumerable.t()) :: Enumerable.t()
  @callback source() :: String.t()
  @callback success_message(Context.t()) :: String.t()
  @callback retry_from_raw(input_identifier :: String.t(), String.t()) ::
              {:ok, [map()]} | {:error, any()}

  @optional_callbacks [retry_from_raw: 2]

  @spec ingest(atom(), atom(), version(), String.t()) :: {:ok, String.t()} | {:error, any()}
  def ingest(embedding_service, source_pipeline, version_tuple, embedding_model) do
    # TODO: Track per-step success/error counts and return a summary
    #   e.g. {:ok, %{persisted: 142, embedded: 138, indexed: 138, errors: 4}}
    # TODO: Partial success should not be reported as full success —
    #   the success_message should reflect how many items actually made it through
    ctx = Pipelines.build_context(__MODULE__, source_pipeline, version_tuple)

    with {:ok, file_paths} <- source_pipeline.download(ctx),
         raw_docs_stream <- source_pipeline.persist_raw_docs(file_paths, ctx),
         parsed_docs_attrs_stream <- source_pipeline.parse(raw_docs_stream),
         persisted_parsed_docs_stream <- persist_parsed_docs(parsed_docs_attrs_stream, ctx),
         docs_with_embeddings_stream <-
           batch_embed(
             persisted_parsed_docs_stream,
             embedding_service,
             source_pipeline,
             embedding_model,
             ctx
           ),
         opensearch_docs_stream <-
           Pipelines.add_to_opensearch(docs_with_embeddings_stream, @index, @cluster, ctx),
         :ok <- Stream.run(opensearch_docs_stream) do
      {:ok, source_pipeline.success_message(ctx)}
    else
      error -> Pipelines.handle_ingest_error(error, ctx)
    end
  end

  @doc """
  Runs the ingestion pipeline, then sweeps up item-level failures.
  Returns the original ingest result. Sweep results are logged.

  Options:
    - :max_sweeps — maximum number of retry passes (default: 2)
  """
  @spec ingest_with_sweep(atom(), atom(), {integer(), integer(), integer()}, String.t(), [
          {:max_sweeps, integer()}
        ]) :: {:ok, String.t()} | {:error, any()}
  def ingest_with_sweep(
        embedding_service,
        source_pipeline,
        version_tuple,
        embedding_model,
        opts \\ []
      ) do
    result = ingest(embedding_service, source_pipeline, version_tuple, embedding_model)

    {major, minor, patch} = version_tuple
    version = Enum.join([major, minor, patch], ".")

    retry_fn = fn failure ->
      retry(failure, source_pipeline, embedding_service, embedding_model)
    end

    {resolved, remaining} =
      Pipelines.sweep(
        "Cake.Documents.Pipeline",
        inspect(source_pipeline),
        version,
        retry_fn,
        opts
      )

    if resolved > 0 or remaining > 0 do
      Logger.info("[docs.sweep] Resolved #{resolved}, remaining #{remaining}")
    end

    result
  end

  @doc """
  Retries a single failed ingest item. Dispatches based on the step that failed:
  persist failures re-run from the raw source doc; embed/index failures resume
  from the existing ParsedDocument.
  """
  @spec retry(struct(), atom(), atom(), String.t()) ::
          {:ok, :retried} | {:error, any()}
  def retry(
        %Cake.FailedIngests.FailedIngest{step: "docs.persist"} = failure,
        source_pipeline,
        embedding_service,
        embedding_model
      ) do
    retry_persist_failure(failure, source_pipeline, embedding_service, embedding_model)
  end

  def retry(
        %Cake.FailedIngests.FailedIngest{step: step} = failure,
        _source_pipeline,
        embedding_service,
        embedding_model
      )
      when step in ["docs.embed", "docs.embed_persist", "opensearch.index"] do
    retry_embed_failure(failure, embedding_service, embedding_model)
  end

  # There seems to be a flaw here. If we use the context function to get all the
  # parsed documents for a given source and version, then we are NOT getting
  # those docs one at a time after their embeddings have been added.
  # Interdasting...
  @spec add_to_opensearch(Enumerable.t()) :: Enumerable.t()
  def add_to_opensearch(docs_with_embeddings_stream) do
    if skip_opensearch?() do
      # In test mode, just pass through the documents without calling OpenSearch
      Stream.map(docs_with_embeddings_stream, fn doc ->
        Logger.debug("Skipping OpenSearch insert for document #{doc.id} (test mode)")
        doc
      end)
    else
      docs_with_embeddings_stream
      |> Task.async_stream(
        &Snap.Document.update(@cluster, @index, %{doc: &1, doc_as_upsert: true}, &1.id),
        max_concurrency: 5,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Stream.map(&handle_opensearch_response/1)
      |> Pipelines.detuple()
    end
  end

  defp skip_opensearch? do
    Application.get_env(:cake, :skip_opensearch, false)
  end

  # NOTE: We need to put together moduledocs for these instead of comments
  # The {:exit, element} tuple is emitted when the process spawned by task.asyn_stream dies
  defp handle_opensearch_response({:exit, element}),
    do: Logger.warning("Failed to insert document #{element.id}. Process died")

  defp handle_opensearch_response({:ok, task_response}),
    do: handle_opensearch_response(task_response)

  defp handle_opensearch_response({:error, changeset}),
    do: Logger.warning("Could not insert document. Changeset: #{inspect(changeset)}")

  defp handle_opensearch_response(%{"_id" => id}),
    do: Logger.info("Document #{id} created in #{@index}")

  # Cake.Documents.Pipeline.batch_embed(:openai, Cake.Documents.Hexdocs.Pipeline, "text-embedding-ada-002", "1.18.3")
  # Need some way of passing parsed docs out one at a time to be persisted to Opensearch
  # What do we use besides Enum.each if we want this to return parsed docs?
  # #TODO a ctx custom type the Dialyzer can expect
  @spec batch_embed(Enumerable.t(), atom(), atom(), String.t(), map()) :: Enumerable.t()
  def batch_embed(
        persisted_parsed_docs_stream,
        embedding_service,
        _source_pipeline,
        embedding_model,
        ctx
      ) do
    embeddings_module = embeddings_module()

    persisted_parsed_docs_stream
    |> Stream.map(fn %ParsedDocument{text: text, title: title} = doc ->
      %{input: "#{title}\n\n#{text}", struct: doc}
    end)
    |> Task.async_stream(
      &embeddings_module.embed(embedding_service, &1, embedding_model),
      max_concurrency: 5,
      timeout: 5_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Pipelines.detuple_with_logging("docs.embed", ctx)
    |> Task.async_stream(
      &handle_response/1,
      max_concurrency: 5,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Pipelines.detuple_with_logging("docs.embed_persist", ctx)
  end

  defp embeddings_module do
    Application.get_env(:cake, :embeddings_module, Cake.Embeddings)
  end

  defp handle_response({:exit, {input, reason}}) do
    {:error, {input.struct.id, inspect(reason)}}
  end

  defp handle_response({:error, error}) do
    {:error, {nil, inspect(error)}}
  end

  defp handle_response({_, {:error, error}}) do
    {:error, {nil, inspect(error)}}
  end

  defp handle_response({_, %{struct: struct, attrs: attrs}}) do
    case ParsedDocuments.update_parsed_document(struct, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, {struct.id, inspect(reason)}}
    end
  end

  # TODO: Return {success_count, error_count} summary after pipeline completes
  defp persist_parsed_docs(parsed_doc_stream, ctx) do
    parsed_doc_stream
    |> Task.async_stream(
      fn attrs ->
        try do
          {:ok, ParsedDocuments.create_parsed_doc!(attrs)}
        rescue
          e -> {:error, {"#{attrs[:package]}@#{attrs[:version]}", Exception.message(e)}}
        end
      end,
      max_concurrency: 5,
      timeout: :infinity
    )
    |> Stream.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:task_exit, reason}}
    end)
    |> Pipelines.detuple_with_logging("docs.persist", ctx)
  end

  defp retry_persist_failure(failure, source_pipeline, embedding_service, embedding_model) do
    if function_exported?(source_pipeline, :retry_from_raw, 2) do
      with {:ok, parsed_attrs_list} <-
             source_pipeline.retry_from_raw(failure.input_identifier, failure.version),
           persisted_docs <-
             Enum.map(parsed_attrs_list, fn attrs ->
               ParsedDocuments.create_parsed_doc!(attrs)
             end),
           :ok <- embed_and_index(persisted_docs, embedding_service, embedding_model) do
        _ = Cake.FailedIngests.delete_failed_ingest(failure)
        {:ok, :retried}
      end
    else
      {:error, {:retry_not_implemented, source_pipeline}}
    end
  end

  defp retry_embed_failure(failure, embedding_service, embedding_model) do
    case Repo.get(ParsedDocument, failure.input_identifier) do
      nil ->
        {:error, {:document_not_found, failure.input_identifier}}

      doc ->
        with :ok <- embed_and_index([doc], embedding_service, embedding_model) do
          _ = Cake.FailedIngests.delete_failed_ingest(failure)
          {:ok, :retried}
        end
    end
  end

  defp embed_and_index(docs, embedding_service, embedding_model) do
    embeddings_module = embeddings_module()

    Enum.reduce_while(docs, :ok, fn doc, :ok ->
      embed_input = %{input: "#{doc.title}\n\n#{doc.text}", struct: doc}

      with {:ok, %{struct: struct, attrs: attrs}} <-
             embeddings_module.embed(embedding_service, embed_input, embedding_model),
           {:ok, updated} <- ParsedDocuments.update_parsed_document(struct, attrs),
           :ok <- index_single(updated) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp index_single(doc) do
    if Application.get_env(:cake, :skip_opensearch, false) do
      :ok
    else
      case Snap.Document.update(@cluster, @index, %{doc: doc, doc_as_upsert: true}, doc.id) do
        %{"_id" => _} -> :ok
        error -> {:error, {:opensearch_index, error}}
      end
    end
  end
end
