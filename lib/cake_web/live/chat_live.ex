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

  ## What the page shows

  The screen takes the wide column and has three parts: the heading, the
  messages, and a bar that stays at the bottom of the screen while the
  messages scroll above it. A question and its answer are daisyUI chat bubbles
  on opposite sides, each under its label ("You", "Cake"); the answer is plain
  text with its line breaks kept (Markdown is not rendered). The sources an
  answer cites are chips under it, numbered as the `[N]` markers in its text
  are: a chip's label opens the source's preview on hover, from the keyboard
  and by tap, and its arrow links to the download. The arrow is there when
  the answer carries a `:download` action for the chip's file (the `actions`
  of `t:Cake.Conversation.Events.response_ready/0`). Under an answer whose
  processing raised warnings is a warning `notice/1`: it says how many
  sources the answer referred to that were not retrieved (the distinct numbers
  among its `[N]` markers that named no passage; every such marker is removed,
  and one written three times counts once), and, for a warning of any other
  kind, that something else went wrong. The previews are placed
  against the row of chips, not centred on their own chip, so one for a narrow
  chip cannot run off the edge of a phone. The two replies ChatLive adds
  itself (a failed turn, a conversation that ended) are `notice/1` errors, not
  bubbles. The messages are a log (`role="log"`), so a screen reader announces
  each one as it arrives. Before the first question the messages are an
  `empty_state/1` with a link to Upload. The bar holds whichever of four
  things the conversation's state calls for: the composer (the question box,
  Send, and the "Manual selection" toggle with a line saying what it does;
  Enter sends, and Send is disabled until there is a question and while there
  is no conversation); a `working/1` line while the conversation works,
  "Searching the documents..." for `:retrieving` and "Working on an answer..."
  for `:generating` (an auto turn reports `:generating` for the whole of it,
  the search included); "Use selected" and "Use all" while documents are being
  chosen, the candidates themselves being cards above it, one per document,
  with a checkbox, the title, the chunk count, the page label and the preview
  ("Use selected" is disabled while none is ticked; a retrieval that found no
  candidates still shows this panel, with nothing in it, #411); and, once the
  conversation has ended, a warning `notice/1` and "Start a new conversation"
  above the disabled composer. One JavaScript hook, `FollowNewest`
  (`assets/js/follow_newest.js`), keeps the newest message in view as the page
  grows, and stops while the reader has scrolled up; a list of candidates
  taller than half the screen opens at its heading instead of its end. Where
  there is a mouse, it also puts the cursor back in the question box when the
  box returns after an answer.
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

  def handle_info(
        {:response_ready,
         %{response: response, citations: citations, actions: actions, warnings: warnings}},
        socket
      ) do
    {:noreply,
     socket
     |> append_message(%{
       role: :assistant,
       text: response,
       citations: citations,
       actions: actions,
       warnings: warnings
     })
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
      to two lines on a phone. The hook keeps the newest message in view
      (assets/js/follow_newest.js). --%>
      <div
        id="chat"
        phx-hook="FollowNewest"
        class="flex min-h-[calc(100dvh-15.5rem)] flex-col sm:min-h-[calc(100dvh-14.5rem)]"
      >
        <div id="chat-messages" class="flex-1 space-y-2 pb-4">
          <%!-- Before the first question: what the screen is for, and where
          to go if there is nothing to ask about yet. --%>
          <.empty_state :if={@messages == []} id="chat-empty" icon="hero-chat-bubble-left-right">
            Ask a question about the uploaded documents.
            <:action>
              <.link navigate={~p"/upload"} class="link link-primary">Upload a document</.link>
            </:action>
          </.empty_state>

          <%!-- A log, so a screen reader announces each message as it is
          added. The empty prompt and the candidates stay outside it. --%>
          <div id="chat-log" role="log" aria-label="Conversation" class="space-y-2">
            <.message
              :for={{msg, i} <- Enum.with_index(Enum.reverse(@messages))}
              id={"msg-#{i}"}
              message={msg}
            />
          </div>

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
              <%!-- An auto turn reports :generating for the whole of it,
              the search included, so this does not say "writing". --%>
              <.working id="chat-generating">Working on an answer...</.working>
            <% :awaiting_selection -> %>
              <.selection_actions selection_form={@selection_form} />
            <% state -> %>
              <%!-- The history above stays, with the reply that reported the
              end; this says what to do about it, where the form is. --%>
              <div :if={state == :ended} class="mb-4 space-y-3">
                <.notice id="chat-ended" kind={:warning} title="This conversation has ended">
                  The messages above stay on the page. A new conversation starts without them:
                  it will not remember what was asked.
                </.notice>
                <%!-- The view's main action while the form under it is
                disarmed, so it has the primary variant and Send does not. --%>
                <.button
                  type="button"
                  id="new-conversation"
                  variant="primary"
                  phx-click="new_conversation"
                >
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
    {hallucinated, other} =
      assigns.message
      |> Map.get(:warnings, [])
      |> Enum.split_with(&match?({:hallucinated_citation, _}, &1))

    assigns =
      assign(assigns,
        hallucinated: length(hallucinated),
        other_warnings?: other != [],
        download_refs: download_refs(Map.get(assigns.message, :actions, []))
      )

    ~H"""
    <div id={@id} class={["chat", if(@message.role == :user, do: "chat-end", else: "chat-start")]}>
      <div class="chat-header text-base-content/70">
        {if @message.role == :user, do: "You", else: "Cake"}
      </div>
      <div data-part="bubble" class={["chat-bubble", @message.role == :user && "chat-bubble-primary"]}>
        <%!-- Plain text with its line breaks kept (Markdown is not rendered),
        so the template's own whitespace must stay out of it. A question can
        be one long unbroken word: it wraps anywhere. --%>
        <p class="whitespace-pre-wrap wrap-anywhere" phx-no-format>{@message.text}</p>
      </div>
      <.sources
        :if={@message[:citations] not in [nil, []]}
        id={@id}
        citations={@message.citations}
        download_refs={@download_refs}
      />
    </div>
    <%!-- What `Cake.Responses` had to say about the answer above. A marker
    that named no retrieved passage is already gone from the text, so the
    notice gives the count of such numbers (each once, however often it was
    written) and not the numbers themselves, which name nothing the reader
    can see. A warning of a kind this page has no wording
    for is still reported, in general terms: what it carries is not shown. --%>
    <.notice
      :if={@hallucinated > 0 or @other_warnings?}
      id={"#{@id}-warning"}
      kind={:warning}
      title="Check this answer against its sources"
    >
      <p :if={@hallucinated > 0} id={"#{@id}-warning-hallucinated"}>
        {hallucinated_text(@hallucinated)}
      </p>
      <p :if={@other_warnings?} id={"#{@id}-warning-other"}>
        Something else went wrong while this answer was being prepared, so it may be
        less reliable than usual.
      </p>
    </.notice>
    """
  end

  @spec hallucinated_text(pos_integer()) :: String.t()
  defp hallucinated_text(1) do
    "It referred to 1 source that was not among the passages retrieved. " <>
      "The reference was removed."
  end

  defp hallucinated_text(count) do
    "It referred to #{count} sources that were not among the passages retrieved. " <>
      "The references were removed."
  end

  # The files an answer offers for download: the `source_ref` of each of its
  # `:download` actions. An action of another kind is not a download.
  @spec download_refs([Cake.Responses.Result.action()]) :: MapSet.t(String.t())
  defp download_refs(actions) when is_list(actions) do
    for %{kind: :download, source_ref: source_ref} <- actions, into: MapSet.new(), do: source_ref
  end

  # The sources an answer cites, as chips under it: each carries the number
  # its `[N]` marker has in the text. A chip has two parts. Its label is
  # focusable and is what the preview describes, so the preview opens on
  # hover, from the keyboard and by tap, as the search screen's page chips
  # do. Its arrow is the link to the source: a label that was itself the
  # link would start the download on the tap meant to open the preview.
  # A chip has the arrow when the answer has a download action for its
  # `source_ref` (`download_refs`), and the arrow is named after the chip: an
  # action's own label is that of the first citation of its file, which for
  # another chip of the same file is another page.
  #
  # daisyUI centres a tooltip on what it is around, and a preview centred on
  # a narrow chip ran off the edge of a phone. So the row is the positioned
  # ancestor (`relative`, with each tooltip `static`): every preview opens
  # above the row, starts where the row starts and is no wider than it. The
  # tail that would point at the chip is hidden, and the chip whose preview
  # is open is ringed instead: on hover, and on focus, which is what a tap
  # gives it (Tailwind applies `hover` only where the device can hover).
  attr :id, :string, required: true
  attr :citations, :list, required: true
  attr :download_refs, MapSet, required: true

  defp sources(assigns) do
    ~H"""
    <div id={"#{@id}-sources"} class="chat-footer relative mt-1 flex-wrap items-center gap-2 text-sm">
      <span class="text-base-content/70">Sources:</span>
      <div :for={cite <- @citations} class="group tooltip static max-w-full after:hidden">
        <%!-- `left-0` puts the preview's centre on the row's start, where
        daisyUI's own transform expects the chip's centre; `translate-x-1/2`
        moves it back by half its width. --%>
        <div
          id={"#{@id}-preview-#{cite.new_index}"}
          role="tooltip"
          class="tooltip-content left-0 max-w-[min(20rem,100%)] translate-x-1/2 text-left"
        >
          {cite.preview}
        </div>
        <span
          id={"#{@id}-source-#{cite.new_index}"}
          class="badge badge-soft badge-primary h-auto min-h-8 gap-1 whitespace-normal py-0.5 text-left ring-primary group-hover:ring-1 group-has-[:focus]:ring-1"
        >
          <span
            tabindex="0"
            aria-describedby={"#{@id}-preview-#{cite.new_index}"}
            class="cursor-help wrap-anywhere"
          >
            [{cite.new_index}] {sanitize_title(cite.label)}
          </span>
          <%!-- A target a finger can hit: 32px, where the icon alone is 16. --%>
          <a
            :if={cite.source_ref in @download_refs}
            href={"/books/download/#{cite.source_ref}"}
            aria-label={"Download #{sanitize_title(cite.label)}"}
            class="-mr-2 flex size-8 flex-none items-center justify-center rounded-full"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
          </a>
        </span>
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
        <%!-- The view's one primary button, except while the form is
        disarmed: then "Start a new conversation" is. --%>
        <.button
          type="submit"
          variant={if !@disabled, do: "primary"}
          disabled={@disabled or not @form.source.valid?}
        >
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
    assigns = assign(assigns, :selected, selected_doc_ids(assigns.selection_form))

    ~H"""
    <%!-- TODO: "Switch to auto" button blocked on backend state machine extension.
         Requires :autoask to be valid from :awaiting_selection. See #136. --%>
    <section id="selection-panel" class="space-y-3 pt-2">
      <div class="flex items-baseline justify-between gap-4">
        <h2 class="font-semibold">Select documents to use</h2>
        <span class="text-sm text-base-content/70">{length(@candidates)} found</span>
      </div>
      <%!-- The buttons that submit this form are in the bar at the bottom of
      the screen (`selection_actions/1`), so they stay reachable under a long
      list. --%>
      <.form
        for={@selection_form}
        id="selection-form"
        phx-submit="submit_selection"
        phx-change="validate_selection"
        class="space-y-3"
      >
        <input type="hidden" name="selection_form[selected_doc_ids][]" value="" />
        <%!-- A card per document, as the search screen does its results. The
        whole card is the checkbox's label. --%>
        <label
          :for={{{doc_id, chunks}, i} <- Enum.with_index(@candidates)}
          id={"candidate-#{i}"}
          class="card card-border cursor-pointer bg-base-100 has-checked:border-primary"
        >
          <% meta = Candidates.document_metadata(chunks) %>
          <div class="card-body flex-row items-start gap-4">
            <input
              type="checkbox"
              name="selection_form[selected_doc_ids][]"
              value={doc_id}
              checked={doc_id in @selected}
              class="checkbox checkbox-primary mt-1"
            />
            <div class="min-w-0 flex-1 space-y-1">
              <h3 data-part="title" class="card-title wrap-anywhere">
                {sanitize_title(meta.title)}
              </h3>
              <p class="text-sm text-base-content/70">
                {length(chunks)} chunk{if length(chunks) != 1, do: "s"}{if meta.page_label,
                  do: " · #{meta.page_label}"}
              </p>
              <p class="text-sm wrap-anywhere">{meta.preview}</p>
            </div>
          </div>
        </label>
      </.form>
    </section>
    """
  end

  # What the bar holds while documents are being chosen: the two ways out of
  # the selection. "Use selected" submits the selection form, which is above
  # it in the page, and is the view's primary action.
  attr :selection_form, :any, required: true

  defp selection_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <button
        type="submit"
        id="use-selected"
        form="selection-form"
        class="btn btn-primary"
        disabled={selected_doc_ids(@selection_form) == []}
      >
        Use selected
      </button>
      <%!-- Disabled while its click is in flight: a second one would reach a
      conversation that is already generating, which has no clause for it. --%>
      <button
        type="button"
        id="use-all"
        phx-click="use_all"
        phx-disable-with="Use all"
        class="btn btn-outline"
      >
        Use all
      </button>
    </div>
    """
  end

  # The document ids the selection form holds, as the changeset cast them:
  # none before the first change.
  @spec selected_doc_ids(Phoenix.HTML.Form.t() | nil) :: [String.t()]
  defp selected_doc_ids(nil), do: []

  defp selected_doc_ids(%Phoenix.HTML.Form{source: changeset}),
    do: Ecto.Changeset.get_field(changeset, :selected_doc_ids) || []

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
