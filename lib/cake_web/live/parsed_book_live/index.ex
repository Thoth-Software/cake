defmodule CakeWeb.ParsedBookLive.Index do
  @moduledoc """
  The documents list, at `/documents`: what has been uploaded, newest
  first, with each document's status. Read-only.

  The module keeps the name `mix phx.gen.live` gave it; to a user the
  screen is "Documents".

  The list is read when the page opens and when the Refresh button is
  pressed, and the page says when that was. Nothing tells the page that an ingest finished: that would need
  the ingestion layer to broadcast. Each row shows what the database says,
  so a status the pipeline left stale (#305) is shown stale.
  """

  use CakeWeb, :live_view

  alias Cake.Books
  alias CakeWeb.Titles

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:documents} width={:wide}>
      <.header>
        Documents
        <:subtitle>
          What has been uploaded, newest first, as of <time
            id="documents-read-at"
            datetime={DateTime.to_iso8601(@read_at)}
            phx-no-format
          >{Calendar.strftime(@read_at, "%H:%M:%S UTC")}</time>.
          Refresh to see new uploads and changed statuses.
        </:subtitle>
        <:actions>
          <.button id="documents-refresh" phx-click="refresh" class="btn btn-ghost">
            <.icon name="hero-arrow-path" class="size-5" /> Refresh
          </.button>
        </:actions>
      </.header>

      <.empty_state :if={@empty?} id="documents-empty" icon="hero-document-text">
        Nothing has been uploaded yet.
        <:action>
          <.link navigate={~p"/upload"} class="link link-primary">Upload a document</.link>
        </:action>
      </.empty_state>

      <.table :if={!@empty?} id="documents" rows={@streams.documents}>
        <:col :let={{_id, parsed_book}} label="Title">
          <.link
            data-part="title"
            navigate={~p"/documents/#{parsed_book.id}"}
            class="link link-hover font-medium wrap-anywhere"
          >
            {Titles.display(parsed_book.title)}
          </.link>
        </:col>
        <:col :let={{_id, parsed_book}} label="Pages" class="hidden sm:table-cell">
          <span data-part="pages">{parsed_book.total_pages || "—"}</span>
        </:col>
        <:col :let={{_id, parsed_book}} label="Status">
          <.status_badge status={parsed_book.embedding_status} />
        </:col>
        <:col :let={{_id, parsed_book}} label="Uploaded" class="hidden sm:table-cell">
          <time
            data-part="uploaded"
            datetime={DateTime.to_iso8601(parsed_book.inserted_at)}
            class="whitespace-nowrap"
          >
            {Calendar.strftime(parsed_book.inserted_at, "%Y-%m-%d %H:%M UTC")}
          </time>
        </:col>
        <:col :let={{_id, parsed_book}} label="Source">
          <.link
            data-part="source"
            aria-label={"Download #{Titles.display(parsed_book.title)}"}
            href={~p"/books/download/#{String.split(parsed_book.source_file_path, "/")}"}
            class="link link-primary"
          >
            <%!-- On a phone the word gives way to an icon, to leave the title
            room. The link is named by its `aria-label`, which says which
            document it fetches. --%>
            <.icon name="hero-arrow-down-tray" class="size-5 sm:hidden" />
            <span class="hidden sm:inline">Download</span>
          </.link>
        </:col>
      </.table>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Documents")
     |> load_documents()}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("refresh", _params, socket) do
    {:noreply, load_documents(socket)}
  end

  # Reads the list again and replaces what the page holds with it, and notes
  # when: a refresh that finds nothing new changes nothing else on the page.
  defp load_documents(socket) do
    parsed_books = Books.list_parsed_books_newest_first()

    socket
    |> assign(:empty?, parsed_books == [])
    |> assign(:read_at, DateTime.utc_now())
    |> stream(:documents, parsed_books, reset: true)
  end
end
