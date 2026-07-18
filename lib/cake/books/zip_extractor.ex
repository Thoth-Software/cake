defmodule Cake.Books.ZipExtractor do
  @moduledoc """
  Extracts PDF files from ZIP archives.

  Uses Erlang's `:zip` module to extract all entries into memory,
  then filters for PDF files. Rejects macOS resource fork entries
  and directory entries.
  """

  @spec extract_pdfs(binary()) :: {:ok, [{String.t(), binary()}]} | {:error, term()}
  def extract_pdfs(zip_binary) when is_binary(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, entries} ->
        pdfs =
          entries
          |> Enum.filter(fn {filename, _binary} -> pdf_file?(filename) end)
          |> Enum.map(fn {filename, binary} -> {List.to_string(filename), binary} end)

        {:ok, pdfs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec pdf_file?(charlist()) :: boolean()
  defp pdf_file?(filename) do
    name = List.to_string(filename)

    not String.starts_with?(name, "__MACOSX/") and
      not String.ends_with?(name, "/") and
      String.ends_with?(String.downcase(name), ".pdf")
  end
end
