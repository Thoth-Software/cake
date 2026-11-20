defmodule CakeWeb.ParsedBookLive.Show do
  use CakeWeb, :live_view

  alias Cake.Books

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Parsed book {@parsed_book.id}
        <:subtitle>This is a parsed_book record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/parsed_books"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/parsed_books/#{@parsed_book}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit parsed_book
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Title">{@parsed_book.title}</:item>
        <:item title="Total pages">{@parsed_book.total_pages}</:item>
        <:item title="Word count">{@parsed_book.word_count}</:item>
        <:item title="Authors">{@parsed_book.authors}</:item>
        <:item title="Embedding status">{@parsed_book.embedding_status}</:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Parsed book")
     |> assign(:parsed_book, Books.get_parsed_book!(id))}
  end
end
