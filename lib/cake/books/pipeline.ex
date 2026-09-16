defmodule Cake.Books.Pipeline do
  @moduledoc """
  Behaviour for ingesting books.

  Note that, unlike the pipeline at Cake.Documents.Pipeline, this module assumes that the files are already persisted. We're looking ahead to a situation where customers already have their pdfs, epubs, or other books already persisted somewhere, *as binary data*.

  Bear in mind, however, that the ParsedBook schema contains everything but the actual content, so each ParsedBook is *also* persisted as a record in postgres.

  ## Usage

  `ingest/4` takes the embedding service, the format pipeline implementing
  this behaviour, the embedding model, and the storage keys of the files to
  ingest (each key is resolved by the format pipeline's `load_binary/1`,
  which reads through the configured `Cake.Books.Adapters` adapter):

      Cake.Books.Pipeline.ingest(
        :openai,
        Cake.Books.Pdf.Pipeline,
        "text-embedding-ada-002",
        ["books/getting-started.pdf"]
      )

  `ingest_with_sweep/5` runs the same pipeline, then retries item-level
  failures via `Cake.Pipelines.sweep/5`.
  """

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Persistence
  alias Cake.Pipelines
  alias Cake.Repo
  alias Cake.Search.Backend
  require Logger

  @doc "Loads the file binary for a storage key, returning the key paired with the binary."
  @callback load_binary(String.t()) :: {:ok, {String.t(), binary()}} | {:error, any()}

  @doc "Parses a loaded `{key, binary}` into a `{ParsedBook, [Chunk]}` pair. Pure transformation."
  @callback parse({String.t(), binary()}) :: {ParsedBook.t(), [Chunk.t()]}

  @doc "The source format this pipeline handles (e.g. `:pdf`)."
  @callback format() :: atom()

  @doc "Human-readable message logged when a run completes."
  @callback success_message() :: String.t()

  @typedoc "Errors from `load_binary/1` implementations. New format pipelines add their shapes here."
  @type load_error :: {String.t(), String.t()}

  @typedoc """
  Errors from single-chunk embedding, persistence, or indexing during retry.

  Each variant tags the failing chunk's ID so the error is traceable.
  """
  @type embed_index_error ::
          {:embed_failed, String.t(), String.t()}
          | {:chunk_update_failed, String.t(), Ecto.Changeset.t()}
          | {:search_backend_index, String.t(), term()}

  @typedoc """
  All reasons that `retry/4` can fail with.

  Composed from subsystem error types: `load_error()` for file reads,
  `Persistence.persist_error()` for transaction failures, and
  `embed_index_error()` for the embed-and-index tail.
  """
  @type retry_error ::
          {:no_input_identifier, String.t()}
          | {:chunk_not_found, String.t()}
          | load_error()
          | Persistence.persist_error()
          | embed_index_error()

  @doc """
  Runs the full ingestion pipeline over the given storage keys: load each
  binary, parse it into a ParsedBook plus Chunks, persist them, embed each
  chunk (its section title prepended to the text), update embedding
  statuses, and index into the search backend.

  Item-level failures are persisted to `FailedIngest` via
  `Pipelines.detuple_with_logging/3`; the return is the honest summary from
  `Pipelines.finalize_ingest/4` — `{:ok, summary}`, or
  `{:error, {:no_items_ingested, summary}}` when nothing made it through.
  """
  @spec ingest(atom(), atom(), String.t(), [String.t()]) ::
          {:ok, Pipelines.ingest_summary()}
          | {:error, {:no_items_ingested, Pipelines.ingest_summary()}}
  def ingest(embedding_service, format_pipeline, embedding_model, paths) do
    ctx = Pipelines.build_context(__MODULE__, format_pipeline, "")
    failures_before = Pipelines.count_failures(ctx)

    with {:ok, binary_stream} <- load_all_binaries(paths, format_pipeline, ctx),
         {:ok, books_and_chunks_stream} <-
           parse_all_binaries(format_pipeline, binary_stream, ctx),
         {:ok, persisted_books_and_chunks} <-
           persist_books_and_chunks(books_and_chunks_stream, ctx),
         {:ok, embedded_books} <-
           embed_all_chunks(persisted_books_and_chunks, embedding_service, embedding_model, ctx),
         status_updated_chunks <- update_book_embedding_statuses(embedded_books),
         indexed_chunks <-
           Pipelines.add_to_search_backend(
             status_updated_chunks,
             ParsedBook.collection_name(),
             ctx
           ) do
      Pipelines.finalize_ingest(
        indexed_chunks,
        ctx,
        failures_before,
        format_pipeline.success_message()
      )
    end
  end

  @doc """
  Runs the ingestion pipeline, then sweeps up item-level failures.
  Returns the original ingest result. Sweep results are logged.

  Options:
    - :max_sweeps — maximum number of retry passes (default: 2)
  """
  @spec ingest_with_sweep(atom(), atom(), String.t(), [String.t()], [{:max_sweeps, integer()}]) ::
          {:ok, Pipelines.ingest_summary()}
          | {:error, {:no_items_ingested, Pipelines.ingest_summary()}}
  def ingest_with_sweep(embedding_service, format_pipeline, embedding_model, paths, opts \\ []) do
    result = ingest(embedding_service, format_pipeline, embedding_model, paths)

    retry_fn = fn failure ->
      retry(failure, format_pipeline, embedding_service, embedding_model)
    end

    {resolved, remaining} =
      Pipelines.sweep(
        "Cake.Books.Pipeline",
        inspect(format_pipeline),
        embedding_model,
        retry_fn,
        opts
      )

    if resolved > 0 or remaining > 0 do
      Logger.info("[books.sweep] Resolved #{resolved}, remaining #{remaining}")
    end

    result
  end

  @doc """
  Retries a single failed ingest item. Dispatches based on the step that failed:
  early failures re-run from the file, embed/index failures resume from the
  persisted chunk.
  """
  @spec retry(Cake.FailedIngests.FailedIngest.t(), atom(), atom(), String.t()) ::
          {:ok, :retried} | {:error, retry_error()}
  def retry(
        %Cake.FailedIngests.FailedIngest{step: step} = failure,
        format_pipeline,
        embedding_service,
        embedding_model
      )
      when step in ["books.load_binary", "books.parse", "books.persist"] do
    retry_from_file(failure, format_pipeline, embedding_service, embedding_model)
  end

  def retry(
        %Cake.FailedIngests.FailedIngest{step: step} = failure,
        _format_pipeline,
        embedding_service,
        embedding_model
      )
      when step in ["books.embed", "search_backend.index"] do
    retry_from_chunk(failure, embedding_service, embedding_model)
  end

  @spec load_all_binaries([String.t()], atom(), Pipelines.Context.t()) :: {:ok, Enumerable.t()}
  def load_all_binaries(paths, format_pipeline, ctx) do
    binary_stream =
      paths
      |> Stream.map(fn path ->
        format_pipeline.load_binary(path)
      end)
      |> Pipelines.detuple_with_logging("books.load_binary", ctx)

    {:ok, binary_stream}
  end

  @spec parse_all_binaries(atom(), Enumerable.t(), Pipelines.Context.t()) :: {:ok, Enumerable.t()}
  def parse_all_binaries(format_pipeline, binary_stream, ctx) do
    books_and_chunks_stream =
      binary_stream
      |> Stream.map(fn binary ->
        try do
          {:ok, format_pipeline.parse(binary)}
        rescue
          e ->
            path =
              case binary do
                {p, _} when is_binary(p) -> p
                _ -> "unknown"
              end

            {:error, {path, Exception.message(e)}}
        end
      end)
      |> Pipelines.detuple_with_logging("books.parse", ctx)

    {:ok, books_and_chunks_stream}
  end

  @spec persist_books_and_chunks(Enumerable.t(), Pipelines.Context.t(), keyword()) ::
          {:ok, Enumerable.t()}
  def persist_books_and_chunks(books_and_chunks_stream, ctx, opts \\ []) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency, System.schedulers_online())

    timeout = Keyword.get(opts, :timeout, :infinity)

    persisted_stream =
      books_and_chunks_stream
      |> Task.async_stream(&Persistence.persist_books_and_chunks/1,
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: false,
        zip_input_on_exit: true
      )
      |> Stream.map(&munge_persisted_stream/1)
      |> Pipelines.detuple_with_logging("books.persist", ctx)

    {:ok, persisted_stream}
  end

  @spec munge_persisted_stream({:ok, term()} | {:exit, term()}) ::
          {:ok, {ParsedBook.t(), [Chunk.t()]}} | {:error, any()}
  def munge_persisted_stream(persisted_books_and_chunks) do
    case persisted_books_and_chunks do
      {:ok, {:ok, persisted}} ->
        {:ok, persisted}

      {:ok, {:error, {path, reason}}} ->
        {:error, {path, inspect(reason)}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, {{%ParsedBook{source_file_path: path}, _chunks}, reason}} ->
        {:error, {path, inspect(reason)}}

      {:exit, {_input, reason}} ->
        {:error, {nil, inspect(reason)}}
    end
  end

  @spec embed_all_chunks(Enumerable.t(), atom(), String.t(), Pipelines.Context.t()) ::
          {:ok, Enumerable.t()}
  def embed_all_chunks(persisted_stream, embedding_service, embedding_model, ctx) do
    embeddings_module = Application.get_env(:cake, :embeddings_module, Cake.Embeddings)

    embedded_stream =
      Stream.map(persisted_stream, fn {book, chunks} ->
        {:ok, book} = Books.update_parsed_book(book, %{embedding_status: :processing})

        embedded_chunks =
          chunks
          |> Task.async_stream(
            fn %Chunk{text: text, section_title: section_title} = chunk ->
              result =
                embeddings_module.embed(
                  embedding_service,
                  %{input: "#{section_title}\n\n#{text}"},
                  embedding_model
                )

              {chunk, result}
            end,
            max_concurrency: 5,
            timeout: 5_000,
            on_timeout: :kill_task,
            zip_input_on_exit: true
          )
          |> Stream.flat_map(&handle_embed_result(&1, ctx))
          |> Enum.to_list()

        {book, length(chunks), embedded_chunks}
      end)

    {:ok, embedded_stream}
  end

  @spec update_book_embedding_statuses(Enumerable.t()) :: Enumerable.t()
  def update_book_embedding_statuses(embedded_books_stream) do
    Stream.flat_map(embedded_books_stream, fn {book, expected_count, embedded_chunks} ->
      status =
        case length(embedded_chunks) do
          ^expected_count -> :completed
          _ -> :failed
        end

      _ = Books.update_parsed_book(book, %{embedding_status: status})
      embedded_chunks
    end)
  end

  defp handle_embed_result({:ok, {chunk, {:ok, %{attrs: attrs}}}}, ctx) do
    case Books.update_chunk(chunk, attrs) do
      {:ok, updated_chunk} ->
        [updated_chunk]

      {:error, reason} ->
        _ = Pipelines.log_and_persist_failure(ctx, "books.embed", {chunk.id, inspect(reason)})
        []
    end
  end

  defp handle_embed_result({:ok, {chunk, {:error, error}}}, ctx) do
    _ = Pipelines.log_and_persist_failure(ctx, "books.embed", {chunk.id, inspect(error)})
    []
  end

  defp handle_embed_result({:exit, {%Chunk{} = chunk, reason}}, ctx) do
    _ = Pipelines.log_and_persist_failure(ctx, "books.embed", {chunk.id, inspect(reason)})
    []
  end

  defp handle_embed_result({:exit, reason}, ctx) do
    _ = Pipelines.log_and_persist_failure(ctx, "books.embed", {nil, inspect(reason)})
    []
  end

  defp retry_from_file(failure, format_pipeline, embedding_service, embedding_model) do
    path = failure.input_identifier

    if is_nil(path) do
      {:error, {:no_input_identifier, failure.id}}
    else
      with {:ok, binary} <- format_pipeline.load_binary(path),
           {parsed_book, chunks} <- try_parse(format_pipeline, binary),
           {:ok, {_persisted_book, persisted_chunks}} <-
             Persistence.persist_books_and_chunks({parsed_book, chunks}),
           :ok <- embed_and_index_chunks(persisted_chunks, embedding_service, embedding_model) do
        _ = Cake.FailedIngests.delete_failed_ingest(failure)
        {:ok, :retried}
      end
    end
  end

  defp try_parse(format_pipeline, binary) do
    format_pipeline.parse(binary)
  rescue
    e -> {:error, {:parse_failed, Exception.message(e)}}
  end

  defp retry_from_chunk(failure, embedding_service, embedding_model) do
    case Repo.get(Chunk, failure.input_identifier) do
      nil ->
        {:error, {:chunk_not_found, failure.input_identifier}}

      chunk ->
        with :ok <- embed_and_index_chunks([chunk], embedding_service, embedding_model) do
          _ = Cake.FailedIngests.delete_failed_ingest(failure)
          {:ok, :retried}
        end
    end
  end

  defp embed_and_index_chunks(chunks, embedding_service, embedding_model) do
    embeddings_module = Application.get_env(:cake, :embeddings_module, Cake.Embeddings)

    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      case embed_single_chunk(chunk, embeddings_module, embedding_service, embedding_model) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp embed_single_chunk(chunk, embeddings_module, embedding_service, embedding_model) do
    input = %{input: "#{chunk.section_title}\n\n#{chunk.text}"}

    case embeddings_module.embed(embedding_service, input, embedding_model) do
      {:ok, %{attrs: attrs}} ->
        case Books.update_chunk(chunk, attrs) do
          {:ok, updated} -> index_single_chunk(updated)
          {:error, reason} -> {:error, {:chunk_update_failed, chunk.id, reason}}
        end

      {:error, reason} ->
        {:error, {:embed_failed, chunk.id, reason}}
    end
  end

  defp index_single_chunk(chunk) do
    if Application.get_env(:cake, :skip_search_backend, false) do
      :ok
    else
      case Backend.backend().index_document(ParsedBook.collection_name(), chunk, chunk.id) do
        :ok -> :ok
        {:error, error} -> {:error, {:search_backend_index, chunk.id, error}}
      end
    end
  end

  @spec persist_parsed_books(any()) :: nil
  def persist_parsed_books(_), do: nil
end
