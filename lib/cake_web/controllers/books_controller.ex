defmodule CakeWeb.BooksController do
  use CakeWeb, :controller

  import Ecto.Query

  alias Cake.Books

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"file_path" => file_path_segments}) do
    file_path = Enum.join(file_path_segments, "/")
    # file_path arrives URL-encoded from the route; Phoenix decodes it.
    # Validate the path is a real ParsedBook to prevent arbitrary file access.
    case Cake.Repo.one(
           from b in Books.ParsedBook,
             where: b.source_file_path == ^file_path,
             limit: 1
         ) do
      nil ->
        not_found(conn, "Book not found")

      %{source_file_path: path} ->
        serve_book(conn, path)
    end
  end

  # Defense in depth: the path came from a ParsedBook row, but refuse to serve
  # anything that resolves outside the configured books root so a poisoned or
  # buggy stored path can't be used to read arbitrary files. The root check
  # runs before any filesystem access, and an out-of-root path is reported as
  # "Book not found" so existence is not revealed.
  defp serve_book(conn, path) do
    cond do
      not within_root?(path) -> not_found(conn, "Book not found")
      not File.exists?(path) -> not_found(conn, "File not found on disk")
      true -> send_book(conn, path)
    end
  end

  defp send_book(conn, path) do
    conn
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{Path.basename(path)}"))
    |> send_file(200, path)
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> text(message)
  end

  defp within_root?(path) do
    root = Path.expand(Application.fetch_env!(:cake, :books_download_root))
    expanded = Path.expand(path)

    expanded == root or String.starts_with?(expanded, root <> "/")
  end
end
