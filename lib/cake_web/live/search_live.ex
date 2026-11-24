defmodule CakeWeb.SearchLive do
  @moduledoc """
  Direct search UI: runs a search against the indexed book collection
  (the `Cake.Books.ParsedBook` GDS is hardcoded) and renders the grouped
  results, without starting a conversation.

  ## What the page shows

  Each book is a card: its title links to the download, and its matching pages
  are chips, each showing the first 200 characters of its chunk on hover, from
  the keyboard and by tap. A preview starts where the row of chips starts and
  is no wider than it, as the chat's are, so one for a chip near the edge
  cannot run off a phone; it opens just above its own chip's line, since a
  book's chips can fill many lines. Its states are the shared state
  components: a search in flight is a `working/1` line, a failed one a
  `notice/1` with a generic message (the reason is only logged), and one that
  finished and found nothing an `empty_state/1` naming the query.
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
       error: nil,
       last_query: nil
     )}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("search", %{"query" => query}, socket) do
    case String.trim(query) do
      "" ->
        {:noreply, socket}

      query ->
        {:noreply,
         socket
         |> assign(loading: true, error: nil)
         |> start_async(:search, fn -> {query, run_search(query)} end)}
    end
  end

  # What the function given to `start_async` in the "search" event returns:
  # the query as it was searched for, and what the search made of it. This
  # module produces it, so the spec below names it; the `:exit` reason comes
  # from the runtime and stays `term()`.
  @typep search_outcome :: {String.t(), {:ok, [book_result()]} | {:error, term()}}

  # One book's hits, as the template shows them.
  @typep book_result :: %{
           book_title: String.t() | nil,
           source_file_path: String.t(),
           total_pages: non_neg_integer() | nil,
           hit_count: pos_integer(),
           pages: [map()]
         }

  @impl Phoenix.LiveView
  @spec handle_async(
          :search,
          {:ok, search_outcome()} | {:exit, term()},
          Phoenix.LiveView.Socket.t()
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:search, {:ok, {query, {:ok, results}}}, socket) do
    {:noreply,
     assign(socket,
       results: results,
       loading: false,
       last_query: query,
       form: to_form(%{"query" => ""})
     )}
  end

  def handle_async(:search, {:ok, {_query, {:error, error}}}, socket) do
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
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:search}>
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

      <.working :if={@loading} id="search-loading">Searching...</.working>

      <.notice :if={@error} id="search-error" kind={:error}>{@error}</.notice>

      <%!-- A finished search that found nothing. It gives way to the
      indicator while the next search runs, and to the error if that fails. --%>
      <.empty_state
        :if={@last_query && @results == [] && !@loading && !@error}
        id="search-empty"
        icon="hero-magnifying-glass"
      >
        No sections matched “{@last_query}”.
      </.empty_state>

      <div :if={@results != []} id="search-results" class="space-y-4">
        <article
          :for={{result, book_index} <- Enum.with_index(@results)}
          class="card card-border bg-base-100"
        >
          <div class="card-body">
            <h2 class="card-title">
              <a
                href={~p"/books/download/#{String.split(result.source_file_path, "/")}"}
                class="link link-hover link-primary"
              >
                {result.book_title}
              </a>
            </h2>
            <p class="text-sm text-base-content/70">
              {result.hit_count} relevant sections found
            </p>
            <%!-- The row is the positioned ancestor and each tooltip is
            `static`, as for the chat's source chips: a preview starts where
            the row starts and is no wider than it. Centred on its own chip,
            as daisyUI places it, one for a chip near the edge ran off a
            phone and made the page scroll sideways. A book can have dozens
            of chips, on many lines, so unlike the chat's the preview is not
            put above the whole row, where it could be a screen away from
            its chip: `bottom-auto` leaves it at its own line, and
            `-translate-y-full` with `-mt-2` lifts it just above that line.
            The tail that would point at the chip is hidden, and the chip
            whose preview is open is ringed instead. --%>
            <div class="relative flex flex-wrap gap-2">
              <%!-- The chip is focusable so the preview opens from the keyboard
              too: daisyUI shows a tooltip on hover and when something inside
              it has focus. --%>
              <div :for={page <- result.pages} class="group tooltip static max-w-full after:hidden">
                <div
                  id={"preview-#{book_index}-#{page.page_number}"}
                  role="tooltip"
                  class="tooltip-content bottom-auto left-0 -mt-2 max-w-[min(20rem,100%)] translate-x-1/2 -translate-y-full text-left"
                >
                  {page.chunk_preview}
                </div>
                <span
                  tabindex="0"
                  aria-describedby={"preview-#{book_index}-#{page.page_number}"}
                  class="badge badge-soft badge-primary h-auto min-h-6 cursor-help whitespace-normal py-0.5 text-left ring-primary group-hover:ring-1 focus:ring-1"
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
