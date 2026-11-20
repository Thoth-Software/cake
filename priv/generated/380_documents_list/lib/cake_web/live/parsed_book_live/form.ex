defmodule CakeWeb.ParsedBookLive.Form do
  use CakeWeb, :live_view

  alias Cake.Books
  alias Cake.Books.ParsedBook

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage parsed_book records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="parsed_book-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:title]} type="text" label="Title" />
        <.input field={@form[:total_pages]} type="number" label="Total pages" />
        <.input field={@form[:word_count]} type="number" label="Word count" />
        <.input
          field={@form[:authors]}
          type="select"
          multiple
          label="Authors"
          options={[{"Option 1", "option1"}, {"Option 2", "option2"}]}
        />
        <.input
          field={@form[:embedding_status]}
          type="select"
          label="Embedding status"
          prompt="Choose a value"
          options={Ecto.Enum.values(Cake.Books.ParsedBook, :embedding_status)}
        />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Parsed book</.button>
          <.button navigate={return_path(@return_to, @parsed_book)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    parsed_book = Books.get_parsed_book!(id)

    socket
    |> assign(:page_title, "Edit Parsed book")
    |> assign(:parsed_book, parsed_book)
    |> assign(:form, to_form(Books.change_parsed_book(parsed_book)))
  end

  defp apply_action(socket, :new, _params) do
    parsed_book = %ParsedBook{}

    socket
    |> assign(:page_title, "New Parsed book")
    |> assign(:parsed_book, parsed_book)
    |> assign(:form, to_form(Books.change_parsed_book(parsed_book)))
  end

  @impl true
  def handle_event("validate", %{"parsed_book" => parsed_book_params}, socket) do
    changeset = Books.change_parsed_book(socket.assigns.parsed_book, parsed_book_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"parsed_book" => parsed_book_params}, socket) do
    save_parsed_book(socket, socket.assigns.live_action, parsed_book_params)
  end

  defp save_parsed_book(socket, :edit, parsed_book_params) do
    case Books.update_parsed_book(socket.assigns.parsed_book, parsed_book_params) do
      {:ok, parsed_book} ->
        {:noreply,
         socket
         |> put_flash(:info, "Parsed book updated successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, parsed_book))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_parsed_book(socket, :new, parsed_book_params) do
    case Books.create_parsed_book(parsed_book_params) do
      {:ok, parsed_book} ->
        {:noreply,
         socket
         |> put_flash(:info, "Parsed book created successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, parsed_book))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _parsed_book), do: ~p"/parsed_books"
  defp return_path("show", parsed_book), do: ~p"/parsed_books/#{parsed_book}"
end
