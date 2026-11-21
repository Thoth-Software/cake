defmodule CakeWeb.ParsedBookLive.Show do
  @moduledoc """
  One document, at `/documents/:id`: the fields the documents list shows,
  and its authors, its word count and how many chunks it was split into.
  Read-only.

  The module keeps the name `mix phx.gen.live` gave it. The page shows what
  the database says, as the list does.
  """

  use CakeWeb, :live_view

  alias Cake.Books
  alias CakeWeb.Titles

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        <span class="wrap-anywhere">{@title}</span>
        <:subtitle>
          <.link id="document-back" navigate={~p"/documents"} class="link link-hover">
            <.icon name="hero-arrow-left" class="size-5" /> Documents
          </.link>
        </:subtitle>
        <:actions>
          <.button
            id="document-source"
            variant="primary"
            href={~p"/books/download/#{String.split(@parsed_book.source_file_path, "/")}"}
          >
            <.icon name="hero-arrow-down-tray" class="size-5" /> Download
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Authors">
          <span id="document-authors" class="wrap-anywhere">{authors(@parsed_book.authors)}</span>
        </:item>
        <:item title="Pages">
          <span id="document-pages">{@parsed_book.total_pages || "—"}</span>
        </:item>
        <:item title="Words">
          <span id="document-word-count">{@parsed_book.word_count}</span>
        </:item>
        <:item title="Chunks">
          <span id="document-chunk-count">{@chunk_count}</span>
        </:item>
        <:item title="Status">
          <span id="document-status">
            <.status_badge status={@parsed_book.embedding_status} />
          </span>
        </:item>
        <:item title="Uploaded">
          <span id="document-uploaded">
            <time datetime={DateTime.to_iso8601(@parsed_book.inserted_at)}>
              {Calendar.strftime(@parsed_book.inserted_at, "%Y-%m-%d %H:%M UTC")}
            </time>
          </span>
        </:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    parsed_book = Books.get_parsed_book!(id)
    title = Titles.display(parsed_book.title)

    {:ok,
     socket
     |> assign(:page_title, title)
     |> assign(:title, title)
     |> assign(:parsed_book, parsed_book)
     |> assign(:chunk_count, Books.count_chunks(parsed_book))}
  end

  defp authors(authors) when authors in [nil, []], do: "—"
  defp authors(authors) when is_list(authors), do: Enum.join(authors, ", ")
end
