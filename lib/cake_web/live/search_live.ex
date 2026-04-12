defmodule CakeWeb.SearchLive do
  use CakeWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       results: [],
       loading: false,
       form: to_form(%{"query" => ""}),
       error: nil
     )}
  end

  def handle_event("search", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, socket}
    else
      socket = assign(socket, loading: true, error: nil)

      result =
        with {:ok, %{attrs: %{embedding: embedding}}} <-
               Cake.Embeddings.embed(:openai, %{input: query}, "text-embedding-ada-002"),
             {:ok, %{hits: hits}} <-
               Cake.Documents.Cluster.search(:hybrid, "chunks_of_books", %{
                 keywords: query,
                 embedding: embedding,
                 keyword_weight: 0.8,
                 fields: ["section_title^2", "text"]
               }) do
          chunks = Cake.Books.chunks_for_hits(hits)

          results =
            chunks
            |> Enum.group_by(fn chunk -> chunk.parsed_book end)
            |> Enum.map(fn {book, book_chunks} ->
              pages =
                book_chunks
                |> Enum.sort_by(& &1.page_number)
                |> Enum.uniq_by(& &1.page_number)
                |> Enum.map(fn chunk ->
                  %{
                    page_number: chunk.page_number,
                    section_title: chunk.section_title,
                    chunk_preview: String.slice(chunk.text, 0, 200)
                  }
                end)

              %{
                book_title: book.title,
                source_file_path: book.source_file_path,
                total_pages: book.total_pages,
                hit_count: length(book_chunks),
                pages: pages
              }
            end)
            |> Enum.sort_by(& &1.hit_count, :desc)

          {:ok, results}
        end

      case result do
        {:ok, results} ->
          {:noreply,
           assign(socket,
             results: results,
             loading: false,
             form: to_form(%{"query" => ""})
           )}

        {:error, error} ->
          {:noreply, assign(socket, loading: false, error: inspect(error))}
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4">
      <h1 class="text-2xl font-bold mb-4">Cake Search</h1>

      <.simple_form for={@form} phx-submit="search">
        <.input field={@form[:query]} type="text" placeholder="Search books..." />
        <:actions>
          <.button type="submit" disabled={@loading}>Search</.button>
        </:actions>
      </.simple_form>

      <div :if={@loading} class="text-gray-500 italic mt-4">Searching...</div>

      <div :if={@error} class="mt-4 p-3 bg-red-100 text-red-700 rounded">
        {@error}
      </div>

      <div :if={@results != []} class="mt-6 space-y-6">
        <div :for={result <- @results} class="border-t pt-4">
          <a
            href={"/books/download/#{result.source_file_path}"}
            class="text-blue-600 hover:underline font-semibold"
          >
            {result.book_title}
          </a>
          <p class="text-gray-500 text-sm mt-0.5">
            {result.hit_count} relevant sections found
          </p>
          <div class="mt-2 flex flex-wrap gap-1">
            <div :for={page <- result.pages} class="relative group inline-block mr-2 mb-1">
              <span class="text-blue-600 cursor-help text-sm">
                p. {page.page_number}
                <span :if={page.section_title} class="text-gray-500">
                  — {page.section_title}
                </span>
              </span>
              <div class="hidden group-hover:block absolute z-10 bottom-full left-0 mb-1 w-80 p-3 bg-gray-800 text-white text-xs rounded shadow-lg">
                {page.chunk_preview}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
