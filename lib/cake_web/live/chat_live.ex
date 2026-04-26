defmodule CakeWeb.ChatLive do
  use CakeWeb, :live_view

  alias Cake.Conversation.Events
  alias CakeWeb.ChatLive.QuestionForm
  alias CakeWeb.ChatLive.SelectionForm

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    conversation_id = Ecto.UUID.generate()

    opts = %{
      id: conversation_id,
      search: Cake.Search.OpenSearch,
      reply_to: self(),
      embedder: "text-embedding-ada-002",
      response_model: "gpt-4o-mini",
      provider: :openai,
      gds: Cake.Books.ParsedBook
    }

    {:ok, pid} = Cake.Conversation.start(opts)
    Process.monitor(pid)
    Phoenix.PubSub.subscribe(Cake.PubSub, Events.topic(conversation_id))

    {:ok,
     assign(socket,
       convo_pid: pid,
       messages: [],
       loading: false,
       citations: [],
       conversation_state: :idle,
       question_form: to_form(QuestionForm.changeset(%{question: "", mode: :auto})),
       candidates: %{},
       available_doc_ids: [],
       selection_form: nil
     )}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("submit", %{"question_form" => params}, socket) do
    changeset = QuestionForm.changeset(params)

    if changeset.valid? do
      question = Ecto.Changeset.get_change(changeset, :question)
      mode = Ecto.Changeset.get_change(changeset, :mode)

      socket =
        assign(socket,
          messages: [%{role: :user, text: question} | socket.assigns.messages],
          loading: true,
          question_form: to_form(QuestionForm.changeset(%{question: "", mode: mode}))
        )

      case mode do
        :auto ->
          Cake.Conversation.autoask(socket.assigns.convo_pid, question)

        :manual ->
          Cake.Conversation.manualask(socket.assigns.convo_pid, question)
      end

      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         question_form: to_form(Map.put(changeset, :action, :validate))
       )}
    end
  end

  def handle_event("submit_selection", %{"selection_form" => params}, socket) do
    changeset = SelectionForm.changeset(params, socket.assigns.available_doc_ids)

    if changeset.valid? do
      selected_doc_ids = Ecto.Changeset.get_change(changeset, :selected_doc_ids, [])
      chunk_ids = expand_to_chunk_ids(selected_doc_ids, socket.assigns.candidates)
      Cake.Conversation.select_docs(socket.assigns.convo_pid, chunk_ids)
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         selection_form: to_form(Map.put(changeset, :action, :validate))
       )}
    end
  end

  def handle_event("use_all", _params, socket) do
    chunk_ids = all_chunk_ids(socket.assigns.candidates)
    Cake.Conversation.select_docs(socket.assigns.convo_pid, chunk_ids)
    {:noreply, socket}
  end

  def handle_event("validate_selection", %{"selection_form" => params}, socket) do
    changeset =
      params
      |> SelectionForm.changeset(socket.assigns.available_doc_ids)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, selection_form: to_form(changeset))}
  end

  def handle_event("validate_question", %{"question_form" => params}, socket) do
    changeset =
      params
      |> QuestionForm.changeset()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, question_form: to_form(changeset))}
  end

  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:convo_response, response, citations}, socket) do
    {:noreply,
     assign(socket,
       messages: [
         %{role: :assistant, text: response, citations: citations} | socket.assigns.messages
       ],
       loading: false,
       citations: citations
     )}
  end

  def handle_info({:convo_error, error}, socket) do
    {:noreply,
     assign(socket,
       messages: [%{role: :assistant, text: "Error: #{inspect(error)}"} | socket.assigns.messages],
       loading: false
     )}
  end

  def handle_info({:state_change, new_state}, socket) do
    {:noreply, assign(socket, conversation_state: new_state)}
  end

  def handle_info({:candidates_ready, candidates}, socket) do
    grouped = group_candidates_by_document(candidates)
    available_doc_ids = grouped |> Map.keys() |> Enum.map(&to_string/1)
    selection_form = to_form(SelectionForm.changeset(%{}, available_doc_ids))

    {:noreply,
     assign(socket,
       conversation_state: :awaiting_selection,
       candidates: grouped,
       available_doc_ids: available_doc_ids,
       selection_form: selection_form
     )}
  end

  def handle_info({:response_ready, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:error, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     assign(socket,
       messages: [
         %{role: :assistant, text: "Error: conversation process crashed (#{inspect(reason)})"}
         | socket.assigns.messages
       ],
       loading: false
     )}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4">
      <h1 class="text-2xl font-bold mb-4">Cake Chat</h1>

      <div class="space-y-4 mb-8">
        <div
          :for={{msg, i} <- Enum.with_index(Enum.reverse(@messages))}
          id={"msg-#{i}"}
          class={[
            "p-3 rounded-lg max-w-xl",
            msg.role == :user && "ml-auto bg-blue-100 text-right",
            msg.role == :assistant && "mr-auto bg-gray-100"
          ]}
        >
          <span class="text-xs font-semibold text-gray-500 block mb-1">
            {if msg.role == :user, do: "You", else: "Cake"}
          </span>
          <span class="text-sm whitespace-pre-wrap">{msg.text}</span>

          <%!-- Citations (assistant messages only) --%>
          <div
            :if={msg[:citations] != nil and msg[:citations] != []}
            class="mt-2 text-sm text-gray-600 border-t pt-2"
          >
            <div class="font-semibold mb-1">Sources:</div>
            <div class="space-y-1">
              <div :for={cite <- msg.citations} class="relative group inline-block">
                <a href={"/books/download/#{cite.source_ref}"} class="text-blue-600 hover:underline">
                  [{cite.new_index}] {sanitize_title(cite.label)}
                </a>
                <%!-- Hover tooltip --%>
                <div class="hidden group-hover:block absolute z-10 bottom-full left-0 mb-1 w-80 p-3 bg-gray-800 text-white text-xs rounded shadow-lg">
                  {cite.preview}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%= case @conversation_state do %>
        <% :generating -> %>
          <div class="flex items-center gap-2 text-gray-500 italic mb-4">
            <span class="inline-block h-2 w-2 rounded-full bg-gray-400 animate-pulse"></span>
            Thinking...
          </div>
        <% :awaiting_selection -> %>
          <div class="mb-4">
            <h2 class="text-lg font-semibold mb-2">Select documents to use</h2>
            <form phx-submit="submit_selection" phx-change="validate_selection">
              <div class="space-y-2 mb-4">
                <%= for {doc_id, chunks} <- @candidates do %>
                  <% meta = candidate_metadata(chunks) %>
                  <label class="flex items-start gap-3 p-3 border rounded-lg hover:bg-gray-50 cursor-pointer">
                    <input
                      type="checkbox"
                      name="selection_form[selected_doc_ids][]"
                      value={doc_id}
                      class="mt-1 rounded border-gray-300"
                    />
                    <div class="flex-1 min-w-0">
                      <div class="font-medium text-sm">{sanitize_title(meta.title)}</div>
                      <div class="text-xs text-gray-500">
                        {length(chunks)} chunk{if length(chunks) != 1, do: "s"}{if meta.page_label,
                          do: " · #{meta.page_label}"}
                      </div>
                      <div class="text-xs text-gray-400 truncate mt-1">{meta.preview}</div>
                    </div>
                  </label>
                <% end %>
              </div>
              <div class="flex gap-2">
                <button
                  type="submit"
                  disabled={not (@selection_form && @selection_form.source.valid?)}
                  class="px-4 py-2 bg-blue-600 text-white rounded disabled:opacity-50"
                >
                  Use selected
                </button>
                <button
                  type="button"
                  phx-click="use_all"
                  class="px-4 py-2 bg-gray-200 text-gray-700 rounded hover:bg-gray-300"
                >
                  Use all
                </button>
              </div>
            </form>
          </div>
        <% _idle -> %>
          <.simple_form for={@question_form} phx-submit="submit" phx-change="validate_question">
            <.input field={@question_form[:question]} type="text" placeholder="Ask a question..." />
            <div class="flex items-center gap-2">
              <input type="hidden" name={@question_form[:mode].name} value="auto" />
              <label class="flex items-center gap-2 text-sm text-gray-600 cursor-pointer">
                <input
                  type="checkbox"
                  name={@question_form[:mode].name}
                  value="manual"
                  checked={to_string(@question_form[:mode].value) == "manual"}
                  class="rounded border-gray-300"
                /> Manual selection
              </label>
            </div>
            <:actions>
              <.button type="submit" disabled={not @question_form.source.valid?}>Send</.button>
            </:actions>
          </.simple_form>
      <% end %>
    </div>
    """
  end

  defp group_candidates_by_document(candidates) do
    Enum.group_by(candidates, fn {chunk, _scores} ->
      meta = Cake.Citable.metadata(chunk)
      meta.source_ref || meta.id
    end)
  end

  defp candidate_metadata(chunks) do
    {first_chunk, _scores} = hd(chunks)
    meta = Cake.Citable.metadata(first_chunk)

    page_numbers =
      chunks
      |> Enum.map(fn {chunk, _} -> Cake.Citable.metadata(chunk).extras[:page_number] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    page_label =
      case page_numbers do
        [] -> nil
        [p] -> "PDF page #{p}"
        pages -> "PDF pages #{List.first(pages)}-#{List.last(pages)}"
      end

    %{
      title: meta.extras[:book_title] || meta.label,
      preview: String.slice(meta.preview, 0, 100),
      page_label: page_label
    }
  end

  defp expand_to_chunk_ids(selected_doc_ids, candidates) do
    selected_doc_ids
    |> Enum.flat_map(fn doc_id ->
      chunks = Map.get(candidates, doc_id, [])
      Enum.map(chunks, fn {chunk, _scores} -> Cake.Citable.metadata(chunk).id end)
    end)
  end

  defp all_chunk_ids(candidates) do
    candidates
    |> Enum.flat_map(fn {_doc_id, chunks} ->
      Enum.map(chunks, fn {chunk, _scores} -> Cake.Citable.metadata(chunk).id end)
    end)
  end

  defp sanitize_title(title) when is_binary(title) do
    title
    |> String.replace(~r/[\x{fffd}\x{0}-\x{1f}]+/u, "")
    |> String.replace(~r/^Microsoft Word - /, "")
    |> String.replace(~r/, p\. (\d+)/, ", PDF page \\1")
    |> String.trim()
  end

  defp sanitize_title(nil), do: "Untitled"
end
