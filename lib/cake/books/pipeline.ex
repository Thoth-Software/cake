defmodule Cake.Books.Pipeline do
  @moduledoc """
  Behaviour for ingesting books.

  Note that, unlike the pipeline at Cake.Documents.Pipeline, this module assumes that the files are already persisted. We're looking ahead to a situation where customers already have their pdfs, epubs, or other books already persisted somewhere, *as binary data*.

  Bear in mind, however, that the ParsedBook schema contains everything but the actual content, so each ParsedBook is *also* persisted as a record in postgres.

  Cake.Books.Pipeline.ingest(:openai, Cake.Books.Pdf.Pipeline,  "text-embedding-ada-002", ["assets/programming_phoenix.pdf"])
  {:ok, pid} = Cake.Conversation.start_link(Cake.Documents.Cluster,"text-embedding-ada-002", "chunks_of_books", "gpt-5", :openai, :keyword)
  Cake.Conversation.ask(pid, "How do socket assigns work in Liveview?", ["title^2", "text"])
  GenServer.cast(pid, :inspect)
  """

  alias Cake.Books
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Pipelines
  require Logger

  @cluster Cake.Documents.Cluster
  @index "chunks_of_books"

  @callback load_binary(String.t()) :: {:ok, binary()} | {:error, any()}
  @callback parse(binary()) :: {ParsedBook.t(), [Chunk.t()]}
  @callback format() :: :pdf
  @callback success_message() :: String.t()

  # We should look into speccing out a FullBook type that equates to a tuple having {%ParsedBook{}, [%Chunk{}]}

  # TODO: Track per-step success/error counts and return a summary
  #   e.g. {:ok, %{persisted: 12, embedded: 10, indexed: 10, errors: 2}}
  # TODO: Persist errors to a dedicated FailedIngest table for retry
  # TODO: Partial success should not be reported as full success —
  #   the success_message should reflect how many items actually made it through
  def ingest(embedding_service, format_pipeline, embedding_model, paths) do
    with {:ok, binary_stream} <- load_all_binaries(paths, format_pipeline),
         {:ok, books_and_chunks_stream} <- parse_all_binaries(format_pipeline, binary_stream),
         {:ok, persisted_books_and_chunks} <- persist_books_and_chunks(books_and_chunks_stream),
         {:ok, embedded_chunks} <-
           embed_all_chunks(persisted_books_and_chunks, embedding_service, embedding_model),
         opensearch_chunks <-
           Pipelines.add_to_opensearch(embedded_chunks, @index, @cluster),
         :ok <- Stream.run(opensearch_chunks) do
      {:ok, format_pipeline.success_message()}
    else
      error -> error
    end
  end

  def load_all_binaries(paths, format_pipeline) do
    binary_stream =
      paths
      |> Stream.map(fn path ->
        format_pipeline.load_binary(path)
      end)
      |> Pipelines.detuple_with_logging("books.load_binary")

    {:ok, binary_stream}
  end

  def parse_all_binaries(format_pipeline, binary_stream) do
    books_and_chunks_stream =
      binary_stream
      |> Stream.map(fn binary ->
        try do
          {:ok, format_pipeline.parse(binary)}
        rescue
          e -> {:error, {binary, Exception.message(e)}}
        end
      end)
      |> Pipelines.detuple_with_logging("books.parse")

    {:ok, books_and_chunks_stream}
  end

  def persist_books_and_chunks(books_and_chunks_stream, opts \\ []) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency, System.schedulers_online())

    timeout = Keyword.get(opts, :timeout, :infinity)

    persisted_stream =
      books_and_chunks_stream
      |> Task.async_stream(&Books.persist_book_and_chunks/1,
        max_concurrency: max_concurrency,
        timeout: timeout,
        ordered: false
      )
      |> Stream.map(fn
        {:ok, {:ok, persisted}} -> {:ok, persisted}
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, reason}
      end)
      |> Pipelines.detuple_with_logging("books.persist")

    {:ok, persisted_stream}
  end

  def embed_all_chunks(persisted_stream, embedding_service, embedding_model) do
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
      |> Stream.flat_map(&handle_embed_result/1)

    {:ok, embedded_stream}
  end

  defp handle_embed_result({:ok, {chunk, {:ok, %{attrs: attrs}}}}) do
    case Books.update_chunk(chunk, attrs) do
      {:ok, updated_chunk} ->
        [updated_chunk]

      {:error, reason} ->
        Logger.warning("Could not update chunk: #{inspect(reason)}")
        []
    end
  end

  defp handle_embed_result({:ok, {_chunk, {:error, error}}}) do
    Logger.warning("ERROR: #{inspect(error)}")
    []
  end

  defp handle_embed_result({:exit, {%Chunk{} = input, reason}}) do
    Logger.warning(
      "EMBEDDING FAILED\n\nReason: #{inspect(reason)}\n\n input: #{input.section_title}"
    )

    []
  end

  defp handle_embed_result({:exit, reason}) do
    Logger.warning("EMBEDDING FAILED\n\nReason: #{inspect(reason)}")
    []
  end

  def persist_parsed_books(_), do: nil
end
