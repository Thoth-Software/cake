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
        conn
        |> put_status(:not_found)
        |> text("Book not found")

      %{source_file_path: path} ->
        if File.exists?(path) do
          filename = Path.basename(path)

          conn
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{filename}")
          )
          |> send_file(200, path)
        else
          conn
          |> put_status(:not_found)
          |> text("File not found on disk")
        end
    end
  end
end
