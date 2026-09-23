defmodule CakeWeb.BooksController do
  @moduledoc """
  Authenticated download of stored book files. `download/2` serves only
  keys recorded as a `ParsedBook`'s `source_file_path`, reading the binary
  through the configured `Cake.Books.Adapters` adapter — the same store
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

  defp serve_book(conn, %Books.ParsedBook{source_file_path: key} = book) do
    case Adapters.adapter().read(key) do
      {:ok, binary} -> send_book(conn, book, binary)
      {:error, _reason} -> not_found(conn, "File not found in storage")
    end
  end

  defp send_book(conn, %Books.ParsedBook{} = book, binary) do
    send_download(conn, {:binary, binary}, filename: download_filename(book))
  end

  # Storage keys carry no extension (see UploadLive.storage_key/2), so the
  # download is named after the key's basename plus the book's source format;
  # a legacy key that already has an extension keeps it. `send_download/3`
  # derives the Content-Type from that filename.
  defp download_filename(%Books.ParsedBook{source_file_path: key, source_format: format}) do
    basename = Path.basename(key)

    if Path.extname(basename) == "" and is_binary(format) and format != "" do
      "#{basename}.#{format}"
    else
      basename
    end
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> text(message)
  end
end
