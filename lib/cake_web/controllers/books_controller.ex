defmodule CakeWeb.BooksController do
  @moduledoc """
  Authenticated download of stored book files. `download/2` serves only
  keys recorded as a `ParsedBook`'s `source_file_path` that also pass
  `Cake.Books.Adapters.valid_key?/1`, reading the binary through the
  configured `Cake.Books.Adapters` adapter — the same store
  `CakeWeb.UploadLive` writes to. Anything else is reported as not found.
  """

  use CakeWeb, :controller

  import Ecto.Query

  alias Cake.Books
  alias Cake.Books.Adapters

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"file_path" => file_path_segments}) do
    key = Enum.join(file_path_segments, "/")
    # The key arrives URL-encoded from the route; Phoenix decodes it. Only a
    # key some ParsedBook row recorded is ever handed to the adapter, so the
    # request cannot name arbitrary storage objects.
    case Cake.Repo.one(
           from b in Books.ParsedBook,
             where: b.source_file_path == ^key,
             limit: 1
         ) do
      nil -> not_found(conn, "Book not found")
      %Books.ParsedBook{} = book -> serve_book(conn, book)
    end
  end

  # Defense in depth: the key came from a ParsedBook row, but a poisoned or
  # legacy row must not be able to climb out of the adapter's root, so a key
  # with a `..` segment is refused before storage is touched and reported as
  # "Book not found" so existence is not revealed.
  defp serve_book(conn, %Books.ParsedBook{source_file_path: key} = book) do
    if Adapters.valid_key?(key) do
      read_book(conn, book)
    else
      not_found(conn, "Book not found")
    end
  end

  defp read_book(conn, %Books.ParsedBook{source_file_path: key} = book) do
    case Adapters.adapter().read(key) do
      {:ok, binary} -> send_book(conn, book, binary)
      {:error, _reason} -> not_found(conn, "File not found in storage")
    end
  end

  defp send_book(conn, %Books.ParsedBook{} = book, binary) do
    send_download(conn, {:binary, binary}, filename: download_filename(book))
  end

  # Storage keys carry no extension (see UploadLive.storage_key/2) but may
  # keep dots from the original name (`guide.v2_<hash>`), so the download is
  # named after the key's basename plus the book's source format unless the
  # basename already ends in that format; a legacy `handbook.pdf` key keeps
  # its name. `send_download/3` derives the Content-Type from the filename.
  defp download_filename(%Books.ParsedBook{source_file_path: key, source_format: format}) do
    basename = Path.basename(key)

    if is_binary(format) and format != "" and not ends_with_format?(basename, format) do
      "#{basename}.#{format}"
    else
      basename
    end
  end

  defp ends_with_format?(basename, format) do
    String.downcase(Path.extname(basename)) == "." <> String.downcase(format)
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> text(message)
  end
end
