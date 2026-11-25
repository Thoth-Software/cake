defmodule CakeWeb.ChatLiveTest do
  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Cake.Conversation.Events
  alias Cake.Search.Provenance
  alias Cake.Search.Result

  setup :register_and_log_in_user

  describe "authentication" do
    test "redirects to the login page when the user is not authenticated" do
      assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/chat")
      assert path =~ "/users/log_in"
    end
  end

  describe "mount" do
    test "renders the chat page in idle state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/chat")

      assert html =~ "Cake Chat"
      assert html =~ "Ask a question..."
      assert has_element?(view, "#question-form button", "Send")
    end

    test "an empty conversation shows a prompt with a link to Upload, not a blank page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#chat-empty")
      assert has_element?(view, ~s(#chat-empty a[href="/upload"]))
      assert has_element?(view, "#chat-empty .hero-chat-bubble-left-right")
      refute has_element?(view, "#msg-0")
    end

    test "the prompt gives way to the first message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> form("#question-form", question_form: %{question: "What is Cake?", mode: "auto"})
      |> render_submit()

      assert has_element?(view, "#msg-0")
      refute has_element?(view, "#chat-empty")
    end

    test "shows manual selection as a labelled toggle with a line saying what it does",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, ~s(label[for="question-mode"]), "Manual selection")

      # A daisyUI toggle is what the issue asks for, so the class is what is
      # pinned.

      assert has_element?(
               view,
               ~s(input#question-mode.toggle[type=checkbox][value=manual][aria-describedby="question-mode-help"])
             )

      assert has_element?(view, "#question-mode-help")
    end

    # The chat is the one screen the conventions give the wide column, and
    # it takes it from the shell rather than setting a width of its own.
    # The hook itself runs in the browser (assets/js/follow_newest.js); what
    # the suite can pin is that the chat asks for it, around both the
    # messages and the form whose submit it listens for.
    test "asks for the hook that keeps the newest message in view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, ~s(#chat[phx-hook="FollowNewest"] #chat-messages))
      assert has_element?(view, ~s(#chat[phx-hook="FollowNewest"] #question-form))
    end

    # A new answer is announced to a screen reader: the messages are a log.
    # The candidates are not in it, or every card would be read out as it
    # arrived.
    test "the messages are a log, and the candidate panel is outside it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(
        view,
        {:response_ready, %{response: "An answer.", citations: [], actions: [], warnings: []}}
      )

      assert has_element?(view, ~s(#chat-log[role="log"] #msg-0), "An answer.")

      broadcast_to_view(view, {:candidates_ready, build_candidates()})
      assert has_element?(view, "#chat-messages #selection-panel")
      refute has_element?(view, "#chat-log #selection-panel")
    end

    test "asks the shell for the wide column", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, ~s(#page[data-width="wide"]))
    end

    test "stops its Conversation when the LiveView process exits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      convo_pid = :sys.get_state(view.pid).socket.assigns.convo_pid
      ref = Process.monitor(convo_pid)

      # A normal stop mirrors the LiveView shutting down on disconnect
      # without taking the test's client proxy (linked to the view) with it.
      GenServer.stop(view.pid, :normal)

      assert_receive {:DOWN, ^ref, :process, ^convo_pid, :normal}
    end

    test "spawns exactly one Conversation process per live mount", %{conn: conn} do
      children_before = DynamicSupervisor.which_children(Cake.ConversationSupervisor)

      {:ok, _view, _html} = live(conn, ~p"/chat")

      children_after = DynamicSupervisor.which_children(Cake.ConversationSupervisor)
      new_children = length(children_after) - length(children_before)
      assert new_children == 1
    end
  end

  describe "question submission" do
    test "appends user message to the chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> form("#question-form", question_form: %{question: "What is Cake?", mode: "auto"})
      |> render_submit()

      assert has_element?(view, "#msg-0", "What is Cake?")
      assert has_element?(view, "#msg-0", "You")
    end

    test "the question and the answer are chat bubbles on opposite sides", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> form("#question-form", question_form: %{question: "What is Cake?", mode: "auto"})
      |> render_submit()

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "A RAG framework.", citations: [], actions: [], warnings: []}}
      )

      # Selected by side, not by position: the submitted question starts a
      # real turn, which may add a reply of its own in between.
      assert has_element?(
               view,
               ~s(#chat-messages .chat-end [data-part="bubble"]),
               "What is Cake?"
             )

      assert has_element?(
               view,
               ~s(#chat-messages .chat-start [data-part="bubble"]),
               "A RAG framework."
             )
    end

    test "the send button is disabled until there is a question to send", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#question-form button[type=submit][disabled]")

      view
      |> form("#question-form", question_form: %{question: "What is Cake?", mode: "auto"})
      |> render_change()

      refute has_element?(view, "#question-form button[type=submit][disabled]")
    end

    # The page now has wording of its own (the empty conversation's prompt),
    # so "no message was added" is the absence of the first message, not of
    # a word.
    test "rejects empty question", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> form("#question-form", question_form: %{question: "", mode: "auto"})
      |> render_submit()

      refute has_element?(view, "#msg-0")
    end
  end

  describe "PubSub-driven state transitions" do
    # The conversation reports its two slow stages separately, and so does
    # the page: each has a line of its own, and never both.
    test ":state_change to :generating says an answer is being written and hides the form",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:state_change, :generating})

      assert has_element?(view, "#chat-generating[role=status]")
      refute has_element?(view, "#chat-retrieving")
      refute has_element?(view, "#question-form")
    end

    test ":state_change to :retrieving says the documents are being searched and hides the form",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:state_change, :retrieving})

      assert has_element?(view, "#chat-retrieving[role=status]")
      refute has_element?(view, "#chat-generating")
      refute has_element?(view, "#question-form")
    end

    # An auto turn reports :generating for the whole of it, the search
    # included (only a manual turn reports :retrieving), so that line must
    # not claim the answer is already being written.
    test "the :generating line does not say which stage the turn is in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:state_change, :generating})

      assert has_element?(view, "#chat-generating", "Working on an answer...")
    end

    test "neither working line is on the page while the conversation is idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      refute has_element?(view, "#chat-retrieving")
      refute has_element?(view, "#chat-generating")
    end

    test ":candidates_ready shows selection panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      candidates = build_candidates()
      broadcast_to_view(view, {:candidates_ready, candidates})

      html = render(view)
      assert html =~ "Select documents to use"
      assert html =~ "Use all"
      assert html =~ "Use selected"
    end

    test ":response_ready appends assistant message and returns to idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:state_change, :generating})
      assert has_element?(view, "#chat-generating")

      payload = %{response: "Here is the answer.", citations: [], actions: [], warnings: []}
      broadcast_to_view(view, {:response_ready, payload})

      assert has_element?(view, "#msg-0", "Here is the answer.")
      assert has_element?(view, "#msg-0", "Cake")
      refute has_element?(view, "#chat-generating")
      assert has_element?(view, "#question-form")
    end

    test ":response_ready with citations renders a numbered chip per source", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"},
        %{new_index: 2, label: "Other Book", source_ref: "def456", preview: "Another snippet"}
      ]

      payload = %{response: "See [1] and [2].", citations: citations, actions: [], warnings: []}
      broadcast_to_view(view, {:response_ready, payload})

      # The chip carries the number its [N] marker has in the answer.
      assert has_element?(view, "#msg-0", "See [1] and [2].")
      assert has_element?(view, "#msg-0-sources #msg-0-source-1", "[1] Test Book")
      assert has_element?(view, "#msg-0-sources #msg-0-source-2", "[2] Other Book")
    end

    # A preview that opened only on hover could not be reached from a
    # keyboard or by tap: the chip's label is focusable and the preview
    # describes it, as the search screen's page chips do.
    test "a source's preview opens from the keyboard and by tap, not only on hover",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"}
      ]

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "See [1].", citations: citations, actions: [], warnings: []}}
      )

      assert has_element?(view, "#msg-0-preview-1[role=tooltip]", "A preview snippet")

      assert has_element?(
               view,
               ~s(#msg-0-source-1 [tabindex="0"][aria-describedby="msg-0-preview-1"])
             )
    end

    # A preview centred on a narrow chip ran off the left edge of a phone, so
    # each is placed against the row of sources instead. Where it lands is a
    # matter of style, which the suite cannot see and a browser check covers;
    # what is pinned here is that the preview is inside the row.
    test "a source's preview sits inside the row of sources",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "FAQ", source_ref: "abc123", preview: "A preview snippet"}
      ]

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "See [1].", citations: citations, actions: [], warnings: []}}
      )

      assert has_element?(view, "#msg-0-sources #msg-0-preview-1[role=tooltip]")
    end

    # The arrow is the answer's download action for the chip's source, not
    # something the chip works out from its own citation: `Cake.Responses`
    # decides what can be downloaded, once. Its name is the chip's own: an
    # action is named after the first citation of its file, which for
    # another chip of that file is another page.
    test "a source's arrow is the download action for its source_ref, named after the chip",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"}
      ]

      actions = [%{kind: :download, label: "The Action's Label", source_ref: "abc123"}]

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "See [1].", citations: citations, actions: actions, warnings: []}}
      )

      assert has_element?(
               view,
               ~s(#msg-0-source-1 a[href="/books/download/abc123"][aria-label="Download Test Book"])
             )
    end

    test "a source with no download action has no arrow, whatever its source_ref",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"},
        %{new_index: 2, label: "Other Book", source_ref: "def456", preview: "Another snippet"}
      ]

      actions = [%{kind: :download, label: "Other Book", source_ref: "def456"}]

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "See [1] and [2].", citations: citations, actions: actions, warnings: []}}
      )

      assert has_element?(view, "#msg-0-source-1", "[1] Test Book")
      refute has_element?(view, "#msg-0-source-1 a")
      assert has_element?(view, ~s(#msg-0-source-2 a[href="/books/download/def456"]))
    end

    # One action per file, and a file can be cited at several places: each
    # of its chips carries the arrow.
    test "two sources in one file share its one download action", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book, p. 3", source_ref: "abc123", preview: "First"},
        %{new_index: 2, label: "Test Book, p. 9", source_ref: "abc123", preview: "Second"}
      ]

      actions = [%{kind: :download, label: "Test Book, p. 3", source_ref: "abc123"}]

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "See [1] and [2].", citations: citations, actions: actions, warnings: []}}
      )

      assert has_element?(
               view,
               ~s(#msg-0-source-1 a[href="/books/download/abc123"][aria-label="Download Test Book, PDF page 3"])
             )

      assert has_element?(
               view,
               ~s(#msg-0-source-2 a[href="/books/download/abc123"][aria-label="Download Test Book, PDF page 9"])
             )
    end

    # The arrow is a download. An action of another kind for the same
    # source_ref is not one, and must not be served from the download route.
    test "an action that is not a download puts no arrow on a chip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"}
      ]

      actions = [%{kind: :external_link, label: "Test Book", source_ref: "abc123"}]

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "See [1].", citations: citations, actions: actions, warnings: []}}
      )

      refute has_element?(view, "#msg-0-source-1 a")
    end

    test "a hallucinated citation is reported in a warning notice under its answer",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"}
      ]

      broadcast_to_view(
        view,
        {:response_ready,
         %{
           response: "See [1].",
           citations: citations,
           actions: [],
           warnings: [{:hallucinated_citation, 7}]
         }}
      )

      # A warning, in the log with the answer it is about, and after it.
      assert has_element?(view, "#chat-log #msg-0-warning.alert-warning")
      assert has_element?(view, "#msg-0 ~ #msg-0-warning, #msg-0 #msg-0-warning")

      # It says how many references were removed, not which number the model
      # wrote: that number names nothing the reader can see.
      assert has_element?(view, "#msg-0-warning #msg-0-warning-hallucinated", "1 source")
      refute has_element?(view, "#msg-0-warning", "7")
      refute has_element?(view, "#msg-0-warning-other")
    end

    test "several hallucinated citations are one notice, with their count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      warnings = [
        {:hallucinated_citation, 7},
        {:hallucinated_citation, 0},
        {:hallucinated_citation, 12}
      ]

      broadcast_to_view(
        view,
        {:response_ready, %{response: "Hm.", citations: [], actions: [], warnings: warnings}}
      )

      assert has_element?(view, "#msg-0-warning-hallucinated", "3 sources")
      # Every marker was hallucinated: no sources, and still the warning.
      refute has_element?(view, "#msg-0-sources")
    end

    test "an answer with no warnings has no warning notice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(
        view,
        {:response_ready, %{response: "Fine.", citations: [], actions: [], warnings: []}}
      )

      assert has_element?(view, "#msg-0", "Fine.")
      refute has_element?(view, "#msg-0-warning")
    end

    # `t:Cake.Responses.Result.warning/0` is open (`{atom, term}`): a kind
    # the page has no wording for is still reported, in general terms, and
    # what it carried stays off the page.
    test "a warning of a kind the page does not know is a general line in the notice",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(
        view,
        {:response_ready,
         %{
           response: "Fine.",
           citations: [],
           actions: [],
           warnings: [{:something_else, "internal-detail"}]
         }}
      )

      assert has_element?(view, "#chat-log #msg-0-warning.alert-warning #msg-0-warning-other")
      refute has_element?(view, "#msg-0-warning-hallucinated")
      refute has_element?(view, "#msg-0-warning", "internal-detail")
      refute has_element?(view, "#msg-0-warning", "something_else")
    end

    test "hallucinated citations and other warnings share one notice, a line each",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      warnings = [{:hallucinated_citation, 7}, {:something_else, "x"}, {:another, 1}]

      broadcast_to_view(
        view,
        {:response_ready, %{response: "Hm.", citations: [], actions: [], warnings: warnings}}
      )

      assert has_element?(view, "#msg-0-warning #msg-0-warning-hallucinated", "1 source")
      assert has_element?(view, "#msg-0-warning #msg-0-warning-other")
    end

    test "each answer keeps its own warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "One.", citations: [], actions: [], warnings: [{:hallucinated_citation, 4}]}}
      )

      broadcast_to_view(
        view,
        {:response_ready, %{response: "Two.", citations: [], actions: [], warnings: []}}
      )

      assert has_element?(view, "#msg-0-warning")
      refute has_element?(view, "#msg-1-warning")
    end

    test "an answer that cites nothing has no sources", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(
        view,
        {:response_ready, %{response: "No idea.", citations: [], actions: [], warnings: []}}
      )

      assert has_element?(view, "#msg-0", "No idea.")
      refute has_element?(view, "#msg-0-sources")
    end

    test ":error shows a safe message without leaking the reason and returns to idle",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:error, :some_failure})

      html = render(view)
      assert html =~ "something went wrong"
      refute html =~ "some_failure"
      # An error reply looks like an error, not like an answer.
      assert has_element?(view, "#msg-0.alert-error[role=alert]", "something went wrong")
      refute has_element?(view, "#msg-0.chat")
      refute has_element?(view, "#chat-retrieving")
      refute has_element?(view, "#chat-generating")
      assert has_element?(view, "#question-form")
    end
  end

  describe "selection panel interactions" do
    test "each candidate document is a card with its title, chunk count, page label and preview, and a checkbox",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:candidates_ready, build_candidates()})

      assert has_element?(view, "#selection-panel", "1 found")
      # A card is what the issue asks for, so the class is what is pinned.
      assert has_element?(view, ~s(#candidate-0.card [data-part="title"]), "Test Book Title")
      assert has_element?(view, "#candidate-0", "1 chunk")
      assert has_element?(view, "#candidate-0", "PDF page 1")
      assert has_element?(view, "#candidate-0", "This is a preview of the chunk content")

      assert has_element?(
               view,
               ~s(#candidate-0 input[type=checkbox][name="selection_form[selected_doc_ids][]"][value="ref-1"])
             )
    end

    test "validate_selection updates form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      candidates = build_candidates()
      broadcast_to_view(view, {:candidates_ready, candidates})

      html =
        view
        |> form("#selection-form", selection_form: %{selected_doc_ids: ["ref-1"]})
        |> render_change()

      assert html =~ "Select documents to use"
      # The server renders what is selected, so a re-render keeps the box
      # checked.
      assert has_element?(view, "#candidate-0 input[type=checkbox][checked]")
    end

    # "Use selected" used to be enabled until the first box had been ticked
    # and unticked again; it now follows the selection itself.
    test "Use selected is disabled exactly while no document is selected, and Use all never is",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:candidates_ready, build_candidates()})

      assert has_element?(view, "#use-selected[disabled]")
      refute has_element?(view, "#use-all[disabled]")

      view
      |> form("#selection-form", selection_form: %{selected_doc_ids: ["ref-1"]})
      |> render_change()

      refute has_element?(view, "#use-selected[disabled]")

      # What a browser sends when the last box is unticked: the hidden
      # field's blank id alone.
      render_change(view, "validate_selection", %{
        "selection_form" => %{"selected_doc_ids" => [""]}
      })

      assert has_element?(view, "#use-selected[disabled]")
    end

    # A second select_docs/2 reaches a conversation that is already
    # generating, which has no clause for it and dies. "Use selected" is a
    # form submit, which LiveView locks; "Use all" is a click, so it disables
    # itself until the click is acknowledged.
    test "Use all disables itself while its click is in flight", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:candidates_ready, build_candidates()})

      assert has_element?(view, "#use-all[phx-disable-with]")
    end

    test "Use selected submits the selection form from the bar under the cards",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:candidates_ready, build_candidates()})

      assert has_element?(view, ~s(button#use-selected[type=submit][form="selection-form"]))
    end
  end

  describe "conversation process crash" do
    test "DOWN message shows a safe message without leaking the crash reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      send(view.pid, {:DOWN, make_ref(), :process, self(), :boom})

      html = render(view)
      assert html =~ "ended unexpectedly"
      refute html =~ "boom"
      assert has_element?(view, "#msg-0.alert-error[role=alert]", "ended unexpectedly")
    end

    test "a dead conversation disarms the question form instead of crashing the view",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      kill_conversation(view)

      assert render(view) =~ "ended unexpectedly"

      # Pushed directly rather than through `form/3`, which refuses a disabled
      # input: this is the submit that left the browser before the re-render.
      html =
        render_submit(view, "submit", %{
          "question_form" => %{"question" => "Still there?", "mode" => "manual"}
        })

      assert Process.alive?(view.pid)
      assert html =~ "ended unexpectedly"
      refute html =~ "Still there?"
      assert has_element?(view, ~s(input[name="question_form[question]"][disabled]))
      assert has_element?(view, "button", "Start a new conversation")
    end

    test "a manual submit that reaches a dead pid before its :DOWN neither crashes the view nor keeps the question",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # The window between the conversation dying and the view handling its
      # :DOWN: the assigned pid is dead but not yet cleared.
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.convo_pid, dead_pid)
      end)

      submitted_html =
        render_submit(view, "submit", %{
          "question_form" => %{"question" => "Still there?", "mode" => "manual"}
        })

      assert Process.alive?(view.pid)
      refute submitted_html =~ "Still there?"

      # The :DOWN that was queued behind the submit then disarms the page.
      send(view.pid, {:DOWN, make_ref(), :process, dead_pid, :killed})

      disarmed_html = render(view)
      assert disarmed_html =~ "ended unexpectedly"
      refute disarmed_html =~ "Still there?"
      assert has_element?(view, "button", "Start a new conversation")
    end

    test "an auto submit that reaches a dead pid before its :DOWN does not keep the question",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # autoask/2 is a cast, so it returns :ok whether or not anything
      # receives it; the question must still not be kept.
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.convo_pid, dead_pid)
      end)

      html =
        render_submit(view, "submit", %{
          "question_form" => %{"question" => "Still there?", "mode" => "auto"}
        })

      assert Process.alive?(view.pid)
      refute html =~ "Still there?"
    end

    test "a document selection that reaches a dead pid before its :DOWN does not crash the view",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      broadcast_to_view(view, {:candidates_ready, build_candidates()})

      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.convo_pid, dead_pid)
      end)

      view |> element("button", "Use all") |> render_click()

      assert Process.alive?(view.pid)
    end

    # The explanation and the way out are one prominent notice, beside the
    # disarmed form rather than a bare button above it.
    test "an ended conversation says so in a notice that offers a new one, and keeps the history",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(
        view,
        {:response_ready,
         %{response: "An earlier answer.", citations: [], actions: [], warnings: []}}
      )

      refute has_element?(view, "#chat-ended")

      kill_conversation(view)

      assert has_element?(view, "#chat-ended.alert-warning[role=alert]")
      assert has_element?(view, "button#new-conversation.btn-primary", "Start a new conversation")
      # One primary button per view: Send gives the variant up while the
      # form is disarmed, and takes it back with a new conversation.
      assert has_element?(view, "#question-form button[type=submit].btn-soft")
      assert has_element?(view, "#msg-0", "An earlier answer.")
      assert has_element?(view, "#msg-1.alert-error", "ended unexpectedly")

      view |> element("#new-conversation") |> render_click()

      refute has_element?(view, "#chat-ended")
      refute has_element?(view, "#new-conversation")
      refute has_element?(view, "#question-form button[type=submit].btn-soft")
      assert has_element?(view, "#msg-0", "An earlier answer.")
      assert has_element?(view, "#msg-1.alert-error", "ended unexpectedly")
    end

    test "starting a new conversation re-arms the form with a live process", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      dead_pid = kill_conversation(view)

      html = view |> element("button", "Start a new conversation") |> render_click()

      new_pid = :sys.get_state(view.pid).socket.assigns.convo_pid
      assert is_pid(new_pid) and new_pid != dead_pid
      assert Process.alive?(new_pid)
      assert html =~ "ended unexpectedly"
      refute has_element?(view, "button", "Start a new conversation")
      refute has_element?(view, ~s(input[name="question_form[question]"][disabled]))

      broadcast_to_view(view, {:state_change, :generating})
      assert has_element?(view, "#chat-generating")
    end

    test "a repeated new_conversation event does not start a second conversation",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      kill_conversation(view)

      # A double-click queues both events before the first patch removes
      # the button, so the second arrives with a live pid already assigned.
      render_click(view, "new_conversation", %{})
      first_pid = :sys.get_state(view.pid).socket.assigns.convo_pid

      render_click(view, "new_conversation", %{})

      assert :sys.get_state(view.pid).socket.assigns.convo_pid == first_pid
    end
  end

  # --- Helpers ---

  # Kills the view's conversation and returns once the view has received the
  # `:DOWN` (traced, so the next call to the view is processed after it).
  defp kill_conversation(view) do
    convo_pid = :sys.get_state(view.pid).socket.assigns.convo_pid
    1 = :erlang.trace(view.pid, true, [:receive])

    Process.exit(convo_pid, :kill)

    assert_receive {:trace, _, :receive, {:DOWN, _, :process, ^convo_pid, :killed}}
    _ = :erlang.trace(view.pid, false, [:receive])
    convo_pid
  end

  defp conversation_id(view) do
    :sys.get_state(view.pid).socket.assigns.convo_pid
    |> :sys.get_state()
    |> Map.get(:id)
  end

  defp broadcast_to_view(view, event) do
    topic = Events.topic(conversation_id(view))
    Phoenix.PubSub.broadcast!(Cake.PubSub, topic, event)
  end

  # Mirrors what `Cake.Conversation` actually broadcasts for manual mode: a list
  # of `Cake.Search.Result` structs (NOT {chunk, scores} tuples).
  defp build_candidates do
    chunk = %Cake.Test.ConvoChunk{
      embedding: [0.1, 0.2, 0.3],
      prompt_text: "sample text",
      metadata: %{
        id: "chunk-1",
        label: "Test Book Title",
        preview: "This is a preview of the chunk content",
        source_ref: "ref-1",
        extras: %{page_number: 1, book_title: "Test Book Title"}
      }
    }

    [
      %Result{
        retrieval_unit: chunk,
        backend_score: 1.0,
        cosine_score: 1.0,
        relevance_score: 1.0,
        hit_source: :search,
        index: "test_index",
        provenance: %Provenance{search_type: :hybrid, query_text: "q"}
      }
    ]
  end
end
