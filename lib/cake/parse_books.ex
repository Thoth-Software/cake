defmodule Cake.ParseBooks do
  use Rustler, otp_app: :cake, crate: "parsebooks"

  @spec extract_pdf(binary()) :: {:ok, Cake.Books.PdfExtraction.t()} | {:error, String.t()}
  def extract_pdf(_binary), do: :erlang.nif_error(:nif_not_loaded)
end
