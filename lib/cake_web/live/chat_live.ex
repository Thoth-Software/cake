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
                  [{cite.new_index}] {cite.label}
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
          <div class="text-gray-500 italic mb-4">Selection pending...</div>

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
                />
                Manual selection
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
      Cake.Citable.metadata(chunk).id
    end)
  end
end
