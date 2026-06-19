defmodule Cake.ParseBooks do
  @moduledoc """
  Rustler NIF wrapper around the `parsebooks` crate. Exposes `extract_pdf/1`,
  which extracts per-page text and metadata from a PDF binary.
  """

  use Rustler, otp_app: :cake, crate: "parsebooks"

  @spec extract_pdf(binary()) :: {:ok, Cake.Books.PdfExtraction.t()} | {:error, String.t()}
  def extract_pdf(_binary), do: :erlang.nif_error(:nif_not_loaded)
end
