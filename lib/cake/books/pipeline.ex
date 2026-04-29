defmodule Cake.Books.Pipeline do
  @moduledoc """
  Behaviour for ingesting books.

  Note that, unlike the pipeline at Cake.Documents.Pipeline, this module assumes that the files are already persisted. We're looking ahead to a situation where customers already have their pdfs, epubs, or other books already persisted somewhere, *as binary data*.

  Bear in mind, however, that the ParsedBook schema contains everything but the actual content, so each ParsedBook is *also* persisted as a record in postgres.

  assets_path = "assets/static"
  filenames = File.ls!(assets_path)
  paths = Enum.map(filenames, &"HASHTAG{assets_path}/HASHTAG{&1}")
  Cake.Books.Pipeline.ingest(:openai, Cake.Books.Pdf.Pipeline,  "text-embedding-ada-002", paths)
  Cake.Books.Pipeline.ingest_with_sweep(:openai, Cake.Books.Pdf.Pipeline,  "text-embedding-ada-002", paths)
  {:ok, pid} = Cake.Conversation.start_link(Cake.Documents.Cluster,"text-embedding-ada-002", "chunks_of_books", "gpt-5", :openai, :keyword)
  Cake.Conversation.autoask(pid, "How do I install the P/N:  98-0110 Rev. A dealkalizer? What's the max flow rate on the SCALA2?")
  GenServer.cast(pid, :inspect)
  """

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Pipelines
  alias Cake.Repo
  require Logger

  @cluster Cake.Documents.Cluster
  @index "chunks_of_books"

  @callback load_binary(String.t()) :: {:ok, {String.t(), binary()}} | {:error, any()}
  @callback parse({String.t(), binary()}) :: {ParsedBook.t(), [Chunk.t()]}
  @callback format() :: atom()
  @callback success_message() :: String.t()

  # We should look into speccing out a FullBook type that equates to a tuple having {%ParsedBook{}, [%Chunk{}]}

  # TODO: Track per-step success/error counts and return a summary
  #   e.g. {:ok, %{persisted: 12, embedded: 10, indexed: 10, errors: 2}}
  # TODO: Partial success should not be reported as full success —
  #   the success_message should reflect how many items actually made it through
  @spec ingest(atom(), atom(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, any()}
  def ingest(embedding_service, format_pipeline, embedding_model, paths) do
    ctx = Pipelines.build_context(__MODULE__, format_pipeline, "")

    with {:ok, binary_stream} <- load_all_binaries(paths, format_pipeline, ctx),
         {:ok, books_and_chunks_stream} <-
           parse_all_binaries(format_pipeline, binary_stream, ctx),
         {:ok, persisted_books_and_chunks} <-
           persist_books_and_chunks(books_and_chunks_stream, ctx),
         {:ok, embedded_chunks} <-
           embed_all_chunks(persisted_books_and_chunks, embedding_service, embedding_model, ctx),
         opensearch_chunks <-
           Pipelines.add_to_opensearch(embedded_chunks, @index, @cluster, ctx),
         :ok <- Stream.run(opensearch_chunks) do
      {:ok, format_pipeline.success_message()}
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
  @spec ingest_with_sweep(atom(), atom(), String.t(), [String.t()], [{:max_sweeps, integer()}]) ::
          {:ok, binary()} | {:error, any()}
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
          {:ok, :retried} | {:error, any()}
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
      when step in ["books.embed", "opensearch.index"] do
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
      |> Task.async_stream(&Books.persist_books_and_chunks/1,
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
      persisted_stream
      |> Stream.flat_map(fn {_book, chunks} -> chunks end)
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

    {:ok, embedded_stream}
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
             Books.persist_books_and_chunks({parsed_book, chunks}),
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
    if Application.get_env(:cake, :skip_opensearch, false) do
      :ok
    else
      case Snap.Document.update(@cluster, @index, %{doc: chunk, doc_as_upsert: true}, chunk.id) do
        %{"_id" => _} -> :ok
        error -> {:error, {:opensearch_index, chunk.id, error}}
      end
    end
  end

  @spec persist_parsed_books(any()) :: nil
  def persist_parsed_books(_), do: nil
end
