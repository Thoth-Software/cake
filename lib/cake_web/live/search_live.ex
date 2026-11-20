defmodule CakeWeb.SearchLive do
  @moduledoc """
  Direct search UI: runs a search against the indexed book collection
  (the `Cake.Books.ParsedBook` GDS is hardcoded) and renders the grouped
  results, without starting a conversation.
  """

  use CakeWeb, :live_view

  alias Cake.Search.Result

  require Logger

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Search",
       results: [],
       loading: false,
       form: to_form(%{"query" => ""}),
       error: nil
     )}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("search", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(loading: true, error: nil)
       |> start_async(:search, fn -> run_search(query) end)}
    end
  end

  @impl Phoenix.LiveView
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:search, {:ok, {:ok, results}}, socket) do
    {:noreply, assign(socket, results: results, loading: false, form: to_form(%{"query" => ""}))}
  end

  def handle_async(:search, {:ok, {:error, error}}, socket) do
    Logger.error("SearchLive search failed: #{inspect(error)}")
    {:noreply, assign(socket, loading: false, error: "Search failed. Please try again.")}
  end

  def handle_async(:search, {:exit, reason}, socket) do
    Logger.error("SearchLive search task crashed: #{inspect(reason)}")
    {:noreply, assign(socket, loading: false, error: "Search failed. Please try again.")}
  end

  defp run_search(query) do
    provider = Application.fetch_env!(:cake, :default_provider)
    embedding_model = Application.fetch_env!(:cake, :default_embedding_model)

    with {:ok, %{attrs: %{embedding: embedding}}} <-
           Cake.Embeddings.embed(provider, %{input: query}, embedding_model),
         {:ok, search_results} <-
           Cake.Search.search_chunks_with_context(
             :hybrid,
             query,
             embedding,
             Cake.Search.default_expand_offset(),
             gds: Cake.Books.ParsedBook,
             embedding_model: embedding_model
           ) do
      results =
        search_results
        |> Enum.group_by(fn %Result{retrieval_unit: chunk} -> chunk.parsed_book end)
        |> Enum.map(fn {book, book_results} -> build_book_result(book, book_results) end)
        |> Enum.sort_by(& &1.hit_count, :desc)

      {:ok, results}
    end
  end

  defp build_book_result(book, book_results) do
    pages =
      book_results
      |> Enum.map(& &1.retrieval_unit)
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
      hit_count: length(book_results),
      pages: pages
    }
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>Cake Search</.header>

      <%!-- The box is a one-shot query: nothing is recovered into it after a
      reconnect, as nothing was before, and it has no change event. --%>
      <.form
        for={@form}
        id="search-form"
        phx-submit="search"
        phx-auto-recover="ignore"
        class="flex items-start gap-2"
      >
        <div class="flex-1">
          <.input field={@form[:query]} type="text" placeholder="Search books..." />
        </div>
        <.button type="submit" variant="primary" disabled={@loading}>Search</.button>
      </.form>

      <div :if={@loading} id="search-loading" class="flex items-center gap-2 text-base-content/70">
        <span class="loading loading-spinner loading-sm"></span> Searching...
      </div>

      <div :if={@error} id="search-error" role="alert" class="alert alert-error">
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
        <span>{@error}</span>
      </div>

      <div :if={@results != []} id="search-results" class="space-y-4">
        <article
          :for={{result, book_index} <- Enum.with_index(@results)}
          class="card card-border bg-base-100"
        >
          <div class="card-body">
            <h2 class="card-title">
              <a
                href={"/books/download/#{result.source_file_path}"}
                class="link link-hover link-primary"
              >
                {result.book_title}
              </a>
            </h2>
            <p class="text-sm text-base-content/70">
              {result.hit_count} relevant sections found
            </p>
            <div class="flex flex-wrap gap-2">
              <%!-- The chip is focusable so the preview opens from the keyboard
              too: daisyUI shows a tooltip on hover and when something inside
              it has focus. --%>
              <div :for={page <- result.pages} class="tooltip max-w-full">
                <div
                  id={"preview-#{book_index}-#{page.page_number}"}
                  role="tooltip"
                  class="tooltip-content max-w-xs text-left"
                >
                  {page.chunk_preview}
                </div>
                <span
                  tabindex="0"
                  aria-describedby={"preview-#{book_index}-#{page.page_number}"}
                  class="badge badge-soft badge-primary h-auto min-h-6 cursor-help whitespace-normal py-0.5 text-left"
                >
                  <span class="whitespace-nowrap">p. {page.page_number}</span>
                  <span :if={page.section_title} class="text-base-content/70">
                    — {page.section_title}
                  </span>
                </span>
              </div>
            </div>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
