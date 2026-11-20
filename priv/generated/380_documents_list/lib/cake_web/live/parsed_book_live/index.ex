defmodule CakeWeb.ParsedBookLive.Index do
  use CakeWeb, :live_view

  alias Cake.Books

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Listing Parsed books
        <:actions>
          <.button variant="primary" navigate={~p"/parsed_books/new"}>
            <.icon name="hero-plus" /> New Parsed book
          </.button>
        </:actions>
      </.header>

      <.table
        id="parsed_books"
        rows={@streams.parsed_books}
        row_click={fn {_id, parsed_book} -> JS.navigate(~p"/parsed_books/#{parsed_book}") end}
      >
        <:col :let={{_id, parsed_book}} label="Title">{parsed_book.title}</:col>
        <:col :let={{_id, parsed_book}} label="Total pages">{parsed_book.total_pages}</:col>
        <:col :let={{_id, parsed_book}} label="Word count">{parsed_book.word_count}</:col>
        <:col :let={{_id, parsed_book}} label="Authors">{parsed_book.authors}</:col>
        <:col :let={{_id, parsed_book}} label="Embedding status">{parsed_book.embedding_status}</:col>
        <:action :let={{_id, parsed_book}}>
          <div class="sr-only">
            <.link navigate={~p"/parsed_books/#{parsed_book}"}>Show</.link>
          </div>
          <.link navigate={~p"/parsed_books/#{parsed_book}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, parsed_book}}>
          <.link
            phx-click={JS.push("delete", value: %{id: parsed_book.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Listing Parsed books")
     |> stream(:parsed_books, list_parsed_books())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    parsed_book = Books.get_parsed_book!(id)
    {:ok, _} = Books.delete_parsed_book(parsed_book)

    {:noreply, stream_delete(socket, :parsed_books, parsed_book)}
  end

  defp list_parsed_books() do
    Books.list_parsed_books()
  end
end
