defmodule Cake.Books.Pdf.Pipeline do
  @moduledoc """
  Implements the Books.Pipeline behaviour for PDFs read from disk.

  Uses the Rust NIF at Cake.ParseBooks to extract page text, then
  builds a {ParsedBook, [Chunk]} tuple for each file.
  """

  @behaviour Cake.Books.Pipeline

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook

  require Logger

  @impl Cake.Books.Pipeline
  def load_binary(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, {path, binary}}
      {:error, reason} -> {:error, {path, "Failed to read: #{inspect(reason)}"}}
    end
  end

  @impl Cake.Books.Pipeline
  @spec parse({any(), binary()}) ::
          {%Cake.Books.ParsedBook{
             __meta__: map(),
             authors: nil,
             chunks: map(),
             embedding_status: :pending,
             file_hash: binary(),
             file_size: non_neg_integer(),
             id: nil,
             inserted_at: nil,
             isbn: nil,
             language: nil,
             metadata: nil,
             parsed_at: map(),
             publication_date: nil,
             publisher: nil,
             source_file_path: any(),
             source_format: <<_::24>>,
             table_of_contents: nil,
             title: binary(),
             total_pages: non_neg_integer(),
             updated_at: nil,
             word_count: non_neg_integer()
           }, list()}
  def parse({path, binary}) do
    {:ok, %{pages: pages, skipped: skipped, title: metadata_title}} =
      Cake.ParseBooks.extract_pdf(binary)

    if skipped != [] do
      skipped_nums = Enum.join(Enum.map(skipped, & &1.page_number), ", ")

      Logger.warning(
        "PDF #{Path.basename(path)}: skipped pages #{skipped_nums} due to extraction errors"
      )
    end

    file_hash = Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

    all_text =
      pages
      |> Enum.sort_by(& &1.page_number)
      |> Enum.map(& &1.text)
      |> Enum.join(" ")

    word_count = count_words(all_text)

    title =
      case metadata_title do
        t when is_binary(t) and t != "" -> t
        _ -> title_fallback(pages, path)
      end

    parsed_book = %ParsedBook{
      title: title,
      source_file_path: path,
      source_format: "pdf",
      file_hash: file_hash,
      file_size: byte_size(binary),
      total_pages: length(pages),
      word_count: word_count,
      parsed_at: DateTime.truncate(DateTime.utc_now(), :second),
      embedding_status: :pending
    }

    chunks =
      pages
      |> Enum.sort_by(& &1.page_number)
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
      |> Enum.reject(&(String.trim(&1.text) == ""))

    {parsed_book, chunks}
  end

  @impl Cake.Books.Pipeline
  def format, do: :pdf

  @impl Cake.Books.Pipeline
  def success_message, do: "Successfully ingested PDF books"

  defp count_words(text) do
    length(String.split(text, ~r/\s+/, trim: true))
  end

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
