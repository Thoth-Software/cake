defmodule Cake.ParseBooks do
  @moduledoc """
  Rustler NIF wrapper around the `parsebooks` crate. Exposes `extract_pdf/1`,
  which extracts per-page text and metadata from a PDF binary.
  """

  use Rustler, otp_app: :cake, crate: "parsebooks"

  @doc """
  Extracts a PDF's per-page text and metadata through the `parsebooks` NIF.

  Takes the PDF binary and returns `{:ok, %Cake.Books.PdfExtraction{}}` — the
  pages in document order as `Cake.Books.PageContent` structs, the pages that
  could not be extracted as `Cake.Books.SkippedPage` structs, and the title the
  crate found — or `{:error, message}` when the crate rejects the binary. A
  malformed PDF is an error tuple, never a crash; the contract is pinned against
  the fixture PDFs by `Cake.ParseBooksTest` in the `integration` CI job.
  """
  @spec extract_pdf(binary()) :: {:ok, Cake.Books.PdfExtraction.t()} | {:error, String.t()}
  def extract_pdf(_binary), do: :erlang.nif_error(:nif_not_loaded)
end
