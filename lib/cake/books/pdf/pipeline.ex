defmodule Cake.Books.Pdf.Pipeline do
  @moduledoc """
  Implements the Books.Pipeline behaviour for PDFs read from disk.

  Uses the Rust NIF at Cake.ParseBooks to extract page text, then
  builds a {ParsedBook, [Chunk]} tuple for each file.
  """

  @behaviour Cake.Books.Pipeline

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook

  @impl true
  def load_binary(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, {path, binary}}
      {:error, reason} -> {:error, {path, "Failed to read: #{inspect(reason)}"}}
    end
  end

  @impl true
  def parse({path, binary}) do
    {:ok, %{pages: pages}} = Cake.ParseBooks.extract_pdf(binary)

    file_hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

    all_text =
      pages
      |> Enum.sort_by(& &1.page_number)
      |> Enum.map(& &1.text)
      |> Enum.join(" ")

    word_count = count_words(all_text)

    title =
      case pages do
        [first | _] -> extract_title(first.text, path)
        [] -> Path.basename(path, ".pdf")
      end

    parsed_book = %ParsedBook{
      title: title,
      source_file_path: path,
      source_format: "pdf",
      file_hash: file_hash,
      file_size: byte_size(binary),
      total_pages: length(pages),
      word_count: word_count,
      parsed_at: DateTime.utc_now() |> DateTime.truncate(:second),
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

  @impl true
  def format, do: :pdf

  @impl true
  def success_message, do: "Successfully ingested PDF books"

  defp count_words(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp extract_title(first_page_text, path) do
    first_page_text
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> Path.basename(path, ".pdf")
      line -> String.trim(line)
    end
    |> case do
      "" -> Path.basename(path, ".pdf")
      title -> title
    end
  end
end
