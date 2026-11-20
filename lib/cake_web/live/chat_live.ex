defmodule CakeWeb.ChatLive do
  @moduledoc """
  The chat UI. Starts a `Cake.Conversation` per LiveView session, owned by
  the LiveView process so it stops when the LiveView does, and subscribes
  to its PubSub topic, rendering state changes, manual-mode candidate
  selection, responses with citations, and errors as they are broadcast
  (see `Cake.Conversation.Events`).

  If the conversation dies, the LiveView survives it: the `:DOWN` handler
  drops the pid (`convo_pid: nil`), keeps the message history, disables the
  question form, and offers a "Start a new conversation" action that starts
  a fresh `Cake.Conversation` with no memory of the earlier turns.
  """

  use CakeWeb, :live_view

  alias Cake.Candidates
  alias Cake.Conversation.Events
  alias CakeWeb.ChatLive.QuestionForm
  alias CakeWeb.ChatLive.SelectionForm

  require Logger

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, socket |> init_ui_state() |> start_conversation()}
    else
      {:ok, init_ui_state(socket)}
    end
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  # Nothing reaches a dead conversation: with no pid the form is disabled,
  # and a submit that races the `:DOWN` is dropped rather than calling it.
  def handle_event(event, _params, %{assigns: %{convo_pid: nil}} = socket)
      when event in ["submit", "submit_selection", "use_all"] do
    {:noreply, socket}
  end

  def handle_event("submit", %{"question_form" => params}, socket) do
    changeset = QuestionForm.changeset(params)

    if changeset.valid? do
      question = Ecto.Changeset.get_change(changeset, :question)
      mode = Ecto.Changeset.get_change(changeset, :mode)

      case dispatch_question(socket.assigns.convo_pid, question, mode) do
        :ok ->
          {:noreply,
           socket
           |> append_message(%{role: :user, text: question})
           |> assign(question_form: to_form(QuestionForm.changeset(%{question: "", mode: mode})))}

        {:error, :conversation_down} ->
          {:noreply, socket}
      end
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

      _ =
        call_conversation(socket.assigns.convo_pid, &Cake.Conversation.select_docs(&1, chunk_ids))

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
    _ = call_conversation(socket.assigns.convo_pid, &Cake.Conversation.select_docs(&1, chunk_ids))
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

  def handle_event("new_conversation", _params, %{assigns: %{convo_pid: nil}} = socket) do
    {:noreply, socket |> start_conversation() |> reset_to_idle()}
  end

  # A duplicate (double-click, or a client sending the event directly) would
  # otherwise start and monitor another owner-bound conversation and orphan
  # the one already assigned.
  def handle_event("new_conversation", _params, socket), do: {:noreply, socket}

  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:state_change, new_state}, socket) do
    {:noreply, assign(socket, conversation_state: new_state)}
  end

  def handle_info({:candidates_ready, candidates}, socket) do
    grouped = Candidates.group_by_document(candidates)
    available_doc_ids = Enum.map(grouped, fn {doc_id, _results} -> doc_id end)
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
       role: :error,
       text: "Sorry, something went wrong while answering your question. Please try again."
     })
     |> reset_to_idle()}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    Logger.error("ChatLive conversation process crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> append_message(%{
       role: :error,
       text: "Sorry, the conversation ended unexpectedly. Please start a new conversation."
     })
     |> reset_to_idle()
     |> assign(convo_pid: nil, conversation_state: :ended)}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:chat} width={:wide}>
      <.header>
        Cake Chat
        <:subtitle>Answers come from the uploaded documents and cite their sources.</:subtitle>
      </.header>

      <%!-- A column that reaches the bottom of the screen, so the bar under
      the messages sits there even when the conversation is short. What is
      subtracted is what the shell and the heading take above and below it:
      the top bar, the page's padding and the heading, whose subtitle runs
      to two lines on a phone. --%>
      <div
        id="chat"
        class="flex min-h-[calc(100dvh-15.5rem)] flex-col sm:min-h-[calc(100dvh-14.5rem)]"
      >
        <div id="chat-messages" class="flex-1 space-y-2 pb-4">
          <.empty_state :if={@messages == []} id="chat-empty">
            Ask a question about the uploaded documents.
            <:action>
              <.link navigate={~p"/upload"} class="link link-primary">Upload a document</.link>
            </:action>
          </.empty_state>

          <.message
            :for={{msg, i} <- Enum.with_index(Enum.reverse(@messages))}
            id={"msg-#{i}"}
            message={msg}
          />

          <.selection_panel
            :if={@conversation_state == :awaiting_selection}
            candidates={@candidates}
            available_doc_ids={@available_doc_ids}
            selection_form={@selection_form}
          />
        </div>

        <%!-- The bar stays at the bottom of the screen while the messages
        scroll above it. It holds the composer, or, while the conversation
        is working, the line saying which of its two stages it is in. --%>
        <div id="chat-bar" class="sticky bottom-0 z-10 border-t border-base-300 bg-base-100 py-4">
          <%= case @conversation_state do %>
            <% :retrieving -> %>
              <.working id="chat-retrieving">Searching the documents...</.working>
            <% :generating -> %>
              <.working id="chat-generating">Writing an answer...</.working>
            <% :awaiting_selection -> %>
            <% state -> %>
              <div :if={state == :ended} class="mb-4">
                <.button type="button" phx-click="new_conversation">
                  Start a new conversation
                </.button>
              </div>
              <.composer form={@question_form} disabled={is_nil(@convo_pid)} />
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # One entry of the history: the user's question on one side, the answer on
  # the other, each under its label. An error reply is a notice, so it does
  # not read as something the documents said.
  attr :id, :string, required: true
  attr :message, :map, required: true

  defp message(%{message: %{role: :error}} = assigns) do
    ~H"""
    <.notice id={@id} kind={:error}>{@message.text}</.notice>
    """
  end

  defp message(assigns) do
    ~H"""
    <div id={@id} class={["chat", if(@message.role == :user, do: "chat-end", else: "chat-start")]}>
      <div class="chat-header text-base-content/70">
        {if @message.role == :user, do: "You", else: "Cake"}
      </div>
      <div class={["chat-bubble", @message.role == :user && "chat-bubble-primary"]}>
        <%!-- Plain text with its line breaks kept (Markdown is not rendered),
        so the template's own whitespace must stay out of it. A question can
        be one long unbroken word: it wraps anywhere. --%>
        <p class="whitespace-pre-wrap wrap-anywhere" phx-no-format>{@message.text}</p>
        <div
          :if={@message[:citations] != nil and @message[:citations] != []}
          class="mt-2 text-sm text-gray-600 border-t pt-2"
        >
          <div class="font-semibold mb-1">Sources:</div>
          <div class="space-y-1">
            <div :for={cite <- @message.citations} class="relative group inline-block">
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

  # The question box, its Send button and the manual-selection toggle. Enter
  # sends: the box is a single-line input in a form.
  attr :form, Phoenix.HTML.Form, required: true
  attr :disabled, :boolean, required: true

  defp composer(assigns) do
    ~H"""
    <.form for={@form} id="question-form" phx-submit="submit" phx-change="validate_question">
      <div class="flex items-start gap-2">
        <div class="flex-1">
          <.input
            field={@form[:question]}
            type="text"
            placeholder="Ask a question..."
            aria-label="Question"
            autocomplete="off"
            disabled={@disabled}
          />
        </div>
        <.button type="submit" variant="primary" disabled={@disabled or not @form.source.valid?}>
          Send
        </.button>
      </div>
      <%!-- The mode is "auto" unless the toggle is on: the hidden field is
      what an unchecked checkbox leaves behind. --%>
      <input type="hidden" name={@form[:mode].name} value="auto" />
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <label for="question-mode" class="label cursor-pointer gap-2 text-base-content">
          <input
            type="checkbox"
            id="question-mode"
            name={@form[:mode].name}
            value="manual"
            checked={to_string(@form[:mode].value) == "manual"}
            aria-describedby="question-mode-help"
            class="toggle toggle-sm toggle-primary"
          /> Manual selection
        </label>
        <span id="question-mode-help" class="text-sm text-base-content/70">
          Choose which documents the answer may use before it is written.
        </span>
      </div>
    </.form>
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
      <.form
        for={@selection_form}
        id="selection-form"
        phx-submit="submit_selection"
        phx-change="validate_selection"
      >
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

  defp none_selected?(nil), do: true
  defp none_selected?(%{params: %{"selected_doc_ids" => []}}), do: true
  defp none_selected?(_), do: false

  @spec start_conversation(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp start_conversation(socket) do
    # TODO: identity strategy is unresolved — every mount gets a fresh
    # conversation id, so conversations are not tied to a user or persisted
    # across reconnects. The conversation's lifetime is this LiveView's: it
    # is started with the LiveView as its owner and stops when it exits.
    conversation_id = Ecto.UUID.generate()

    opts =
      :cake
      |> Application.fetch_env!(Cake.Conversation)
      |> Map.new()
      |> Map.put(:id, conversation_id)
      |> Map.put(:owner, self())

    {:ok, pid} = Cake.Conversation.start(opts)
    Process.monitor(pid)

    case Phoenix.PubSub.subscribe(Cake.PubSub, Events.topic(conversation_id)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("ChatLive failed to subscribe to conversation topic: #{inspect(reason)}")
    end

    assign(socket, convo_pid: pid)
  end

  @spec init_ui_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp init_ui_state(socket) do
    assign(socket,
      page_title: "Chat",
      convo_pid: nil,
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

  @spec dispatch_question(pid(), String.t(), :auto | :manual) ::
          :ok | {:error, :conversation_down}
  # autoask/2 is a cast and reports :ok even to a dead pid, so the dead case
  # is checked here; a dead pid stays dead, so this check never misreports
  # one. It is not atomic with the cast: a conversation that dies after the
  # check but before the cast lands drops the question while the page keeps
  # it, and its :DOWN then reports the loss like a mid-turn crash. Closing
  # that needs autoask/2 to acknowledge acceptance (#311).
  defp dispatch_question(convo_pid, question, :auto) do
    if Process.alive?(convo_pid),
      do: Cake.Conversation.autoask(convo_pid, question),
      else: {:error, :conversation_down}
  end

  defp dispatch_question(convo_pid, question, :manual),
    do: call_conversation(convo_pid, &Cake.Conversation.manualask(&1, question))

  # The conversation can die after an event is queued but before its :DOWN is
  # handled (or while the call waits), so the call exits with :noproc or the
  # conversation's exit reason. A dead pid guarantees the :DOWN is on its way
  # to disarm the page, so the exit is absorbed; any other exit (a timeout
  # against a live conversation) propagates as before.
  @spec call_conversation(pid(), (pid() -> result)) :: result | {:error, :conversation_down}
        when result: term()
  defp call_conversation(convo_pid, call) do
    call.(convo_pid)
  catch
    :exit, reason ->
      if Process.alive?(convo_pid),
        do: :erlang.raise(:exit, reason, __STACKTRACE__),
        else: {:error, :conversation_down}
  end

  # How a title is displayed is shared with the documents list (#380). The
  # chat shows citation labels, whose page is spelled out; a candidate's
  # title goes the same way, as it did before the function was shared.
  defp sanitize_title(title), do: CakeWeb.Titles.display_citation_label(title)

  defp current_mode(socket) do
    case Ecto.Changeset.get_field(socket.assigns.question_form.source, :mode) do
      nil -> :auto
      mode -> mode
    end
  end
end
