defmodule Cake.Books.Pdf.Pipeline do
  @moduledoc """
  Implements the Books.Pipeline behaviour for PDFs.

  `load_binary/1` reads each PDF through the configured
  `Cake.Books.Adapters` storage adapter (disk or S3). Uses the Rust NIF at
  Cake.ParseBooks to extract page text, then builds a {ParsedBook, [Chunk]}
  tuple for each file.
  """

  @behaviour Cake.Books.Pipeline

  alias Cake.Books.Chunk
  alias Cake.Books.PageContent
  alias Cake.Books.ParsedBook
  alias Cake.Books.SkippedPage

  require Logger

  @type extraction() :: %{
          pages: [PageContent.t()],
          skipped: [SkippedPage.t()],
          title: String.t(),
          source_file_path: String.t(),
          file_hash: String.t(),
          file_size: non_neg_integer(),
          total_pages: non_neg_integer(),
          word_count: non_neg_integer()
        }

  @impl Cake.Books.Pipeline
  @spec load_binary(String.t()) ::
          {:ok, {String.t(), binary()}} | {:error, {String.t(), String.t()}}
  def load_binary(key) do
    adapter = Cake.Books.Adapters.adapter()

    case adapter.read(key) do
      {:ok, binary} -> {:ok, {key, binary}}
      {:error, reason} -> {:error, {key, "Failed to read: #{inspect(reason)}"}}
    end
  end

  @impl Cake.Books.Pipeline
  @spec parse({String.t(), binary()}) :: {ParsedBook.t(), [Chunk.t()]}
  def parse({path, binary}) do
    extracted = extract(path, binary)
    warn_skipped(extracted)
    {build_parsed_book(extracted), build_chunks(extracted.pages)}
  end

  @spec extract(String.t(), binary()) :: extraction()
  defp extract(path, binary) do
    {:ok, %{pages: pages, skipped: skipped, title: metadata_title}} =
      Cake.ParseBooks.extract_pdf(binary)

    sorted_pages = Enum.sort_by(pages, & &1.page_number)
    all_text = sorted_pages |> Enum.map(& &1.text) |> Enum.join(" ")

    %{
      pages: sorted_pages,
      skipped: skipped,
      title: resolve_title(metadata_title, sorted_pages, path),
      source_file_path: path,
      file_hash: Base.encode16(:crypto.hash(:sha256, binary), case: :lower),
      file_size: byte_size(binary),
      total_pages: length(sorted_pages) + length(skipped),
      word_count: count_words(all_text)
    }
  end

  @spec warn_skipped(extraction()) :: :ok
  defp warn_skipped(%{skipped: []}), do: :ok

  defp warn_skipped(%{source_file_path: path, skipped: skipped}) do
    skipped_nums = Enum.join(Enum.map(skipped, & &1.page_number), ", ")

    Logger.warning(
      "PDF #{Path.basename(path)}: skipped pages #{skipped_nums} due to extraction errors"
    )
  end

  @spec build_parsed_book(extraction()) :: ParsedBook.t()
  defp build_parsed_book(extracted) do
    %ParsedBook{
      title: extracted.title,
      source_file_path: extracted.source_file_path,
      source_format: "pdf",
      file_hash: extracted.file_hash,
      file_size: extracted.file_size,
      total_pages: extracted.total_pages,
      word_count: extracted.word_count,
      parsed_at: DateTime.truncate(DateTime.utc_now(), :second),
      embedding_status: :pending
    }
  end

  @spec build_chunks([PageContent.t()]) :: [Chunk.t()]
  defp build_chunks(pages) do
    # Reject blank pages BEFORE assigning chunk_index so the indices stay dense.
    # Indexing first and rejecting after leaves holes that break neighbor
    # expansion and page-range queries downstream.
    pages
    |> Enum.reject(&(String.trim(&1.text) == ""))
    |> Enum.with_index()
    |> Enum.map(fn {page, index} ->
      %Chunk{
        text: page.text,
        page_number: page.page_number,
        chunk_index: index,
        word_count: count_words(page.text),
        char_count: String.length(page.text)
      }
    end)
  end

  @impl Cake.Books.Pipeline
  @spec format() :: atom()
  def format, do: :pdf

  @impl Cake.Books.Pipeline
  @spec success_message() :: String.t()
  def success_message, do: "Successfully ingested PDF books"

  defp count_words(text) do
    length(String.split(text, ~r/\s+/, trim: true))
  end

  # The title fallback chain: a non-blank metadata title wins; otherwise the
  # first line of the first extracted page; otherwise the filename.
  defp resolve_title(metadata_title, _pages, _path)
       when is_binary(metadata_title) and metadata_title != "",
       do: metadata_title

  defp resolve_title(_metadata_title, pages, path), do: title_fallback(pages, path)

  defp title_fallback(pages, path) do
    case pages do
      [first | _] ->
        raw_line =
          first.text
          |> String.split("\n", trim: true)
          |> List.first()

        trimmed =
          case raw_line do
            nil -> Path.basename(path, ".pdf")
            line -> String.trim(line)
          end

        case trimmed do
          "" -> Path.basename(path, ".pdf")
          title -> title
        end

      [] ->
        Path.basename(path, ".pdf")
    end
  end
end
