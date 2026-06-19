defmodule CakeWeb.ChatLive do
  use CakeWeb, :live_view

  alias Cake.Candidates
  alias Cake.Conversation.Events
  alias CakeWeb.ChatLive.QuestionForm
  alias CakeWeb.ChatLive.SelectionForm

  require Logger

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, socket |> start_conversation() |> init_ui_state()}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("submit", %{"question_form" => params}, socket) do
    changeset = QuestionForm.changeset(params)

    if changeset.valid? do
      question = Ecto.Changeset.get_change(changeset, :question)
      mode = Ecto.Changeset.get_change(changeset, :mode)

      {:noreply,
       socket
       |> append_message(%{role: :user, text: question})
       |> assign(question_form: to_form(QuestionForm.changeset(%{question: "", mode: mode})))
       |> dispatch_question(question, mode)}
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
      chunk_ids = Candidates.expand_to_chunk_ids(selected_doc_ids, socket.assigns.candidates)
      _ = Cake.Conversation.select_docs(socket.assigns.convo_pid, chunk_ids)
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         selection_form: to_form(Map.put(changeset, :action, :validate))
       )}
    end
  end

  def handle_event("use_all", _params, socket) do
    chunk_ids = Candidates.all_chunk_ids(socket.assigns.candidates)
    _ = Cake.Conversation.select_docs(socket.assigns.convo_pid, chunk_ids)
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
  def handle_info({:state_change, new_state}, socket) do
    {:noreply, assign(socket, conversation_state: new_state)}
  end

  def handle_info({:candidates_ready, candidates}, socket) do
    grouped = Candidates.group_by_document(candidates)
    available_doc_ids = Enum.map(grouped, fn {doc_id, _} -> to_string(doc_id) end)
    selection_form = to_form(SelectionForm.changeset(%{}, available_doc_ids))

    {:noreply,
     assign(socket,
       conversation_state: :awaiting_selection,
       candidates: grouped,
       available_doc_ids: available_doc_ids,
       selection_form: selection_form
     )}
  end

  def handle_info({:response_ready, %{response: response, citations: citations}}, socket) do
    {:noreply,
     socket
     |> append_message(%{role: :assistant, text: response, citations: citations})
     |> reset_to_idle()}
  end

  def handle_info({:error, reason}, socket) do
    Logger.error("ChatLive conversation error: #{inspect(reason)}")

    {:noreply,
     socket
     |> append_message(%{
       role: :assistant,
       text: "Sorry, something went wrong while answering your question. Please try again."
     })
     |> reset_to_idle()}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    Logger.error("ChatLive conversation process crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> append_message(%{
       role: :assistant,
       text: "Sorry, the conversation ended unexpectedly. Please start a new question."
     })
     |> reset_to_idle()}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4">
      <h1 class="text-2xl font-bold mb-4">Cake Chat</h1>
      <.message_list messages={@messages} />

      <%= case @conversation_state do %>
        <% :generating -> %>
          <.thinking_indicator />
        <% :awaiting_selection -> %>
          <.selection_panel
            candidates={@candidates}
            available_doc_ids={@available_doc_ids}
            selection_form={@selection_form}
          />
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

  attr :messages, :list, required: true

  defp message_list(assigns) do
    ~H"""
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
              <div class="hidden group-hover:block absolute z-10 bottom-full left-0 mb-1 w-80 p-3 bg-gray-800 text-white text-xs rounded shadow-lg">
                {cite.preview}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :candidates, :list, required: true
  attr :available_doc_ids, :list, required: true
  attr :selection_form, :any, required: true

  defp selection_panel(assigns) do
    ~H"""
    <%!-- TODO: "Switch to auto" button blocked on backend state machine extension.
         Requires :autoask to be valid from :awaiting_selection. See #136. --%>
    <div class="mb-4">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-lg font-semibold">Select documents to use</h2>
        <span class="text-xs text-gray-400">{length(@candidates)} found</span>
      </div>
      <.form for={@selection_form} phx-submit="submit_selection" phx-change="validate_selection">
        <input type="hidden" name="selection_form[selected_doc_ids][]" value="" />
        <div class="space-y-2 mb-4 max-h-80 overflow-y-auto">
          <%= for {doc_id, chunks} <- @candidates do %>
            <% meta = Candidates.document_metadata(chunks) %>
            <label class="flex items-start gap-3 p-3 border border-gray-200 rounded-lg hover:border-blue-300 hover:bg-blue-50/50 cursor-pointer transition-colors">
              <input
                type="checkbox"
                name="selection_form[selected_doc_ids][]"
                value={doc_id}
                class="mt-0.5 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <div class="flex-1 min-w-0">
                <div class="font-medium text-sm text-gray-900">
                  {sanitize_title(meta.title)}
                </div>
                <div class="text-xs text-gray-500 mt-0.5">
                  {length(chunks)} chunk{if length(chunks) != 1, do: "s"}{if meta.page_label,
                    do: " · #{meta.page_label}"}
                </div>
                <div class="text-xs text-gray-400 truncate mt-1">{meta.preview}</div>
              </div>
            </label>
          <% end %>
        </div>
        <div class="flex gap-2 pt-2 border-t border-gray-100">
          <button
            type="submit"
            disabled={none_selected?(@selection_form)}
            class="px-4 py-2 bg-white text-sm font-medium border border-gray-300 rounded-lg hover:bg-gray-50  disabled:cursor-not-allowed disabled:opacity-20"
          >
            Use selected
          </button>
          <button
            type="button"
            phx-click="use_all"
            class="px-4 py-2 bg-white text-sm font-medium border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
          >
            Use all
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp thinking_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-gray-500 italic mb-4">
      <span class="inline-block h-2 w-2 rounded-full bg-gray-400 animate-pulse"></span> Thinking...
    </div>
    """
  end

  defp none_selected?(nil), do: true
  defp none_selected?(%{params: %{"selected_doc_ids" => []}}), do: true
  defp none_selected?(_), do: false

  @spec start_conversation(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp start_conversation(socket) do
    # TODO: identity strategy is unresolved — every mount gets a fresh
    # conversation id, so conversations are not tied to a user or persisted
    # across reconnects.
    conversation_id = Ecto.UUID.generate()

    opts =
      :cake
      |> Application.fetch_env!(Cake.Conversation)
      |> Map.new()
      |> Map.put(:id, conversation_id)

    {:ok, pid} = Cake.Conversation.start(opts)
    Process.monitor(pid)
    _ = Phoenix.PubSub.subscribe(Cake.PubSub, Events.topic(conversation_id))

    assign(socket, convo_pid: pid)
  end

  @spec init_ui_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp init_ui_state(socket) do
    assign(socket,
      messages: [],
      conversation_state: :idle,
      question_form: to_form(QuestionForm.changeset(%{question: "", mode: :auto})),
      candidates: [],
      available_doc_ids: [],
      selection_form: nil
    )
  end

  @spec reset_to_idle(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reset_to_idle(socket) do
    assign(socket,
      conversation_state: :idle,
      candidates: [],
      available_doc_ids: [],
      selection_form: nil,
      question_form: to_form(QuestionForm.changeset(%{question: "", mode: current_mode(socket)}))
    )
  end

  @spec append_message(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  defp append_message(socket, message) do
    assign(socket, messages: [message | socket.assigns.messages])
  end

  @spec dispatch_question(Phoenix.LiveView.Socket.t(), String.t(), :auto | :manual) ::
          Phoenix.LiveView.Socket.t()
  defp dispatch_question(socket, question, mode) do
    _ =
      case mode do
        :auto -> Cake.Conversation.autoask(socket.assigns.convo_pid, question)
        :manual -> Cake.Conversation.manualask(socket.assigns.convo_pid, question)
      end

    socket
  end

  defp sanitize_title(title) when is_binary(title) do
    title
    |> String.replace(~r/[\x{fffd}\x{0}-\x{1f}]+/u, "")
    |> String.replace(~r/^Microsoft Word - /, "")
    |> String.replace(~r/, p\. (\d+)/, ", PDF page \\1")
    |> String.trim()
  end

  defp sanitize_title(nil), do: "Untitled"

  defp current_mode(socket) do
    case Ecto.Changeset.get_field(socket.assigns.question_form.source, :mode) do
      nil -> :auto
      mode -> mode
    end
  end
end
