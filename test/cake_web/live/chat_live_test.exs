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
      assert has_element?(view, "button", "Send")
    end

    test "shows manual selection toggle", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ "Manual selection"
    end
  end

  describe "question submission" do
    test "appends user message to the chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      html =
        view
        |> form("form", question_form: %{question: "What is Cake?", mode: "auto"})
        |> render_submit()

      assert html =~ "What is Cake?"
      assert html =~ "You"
    end

    test "rejects empty question", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      html =
        view
        |> form("form", question_form: %{question: "", mode: "auto"})
        |> render_submit()

      refute html =~ "You"
    end
  end

  describe "PubSub-driven state transitions" do
    test ":state_change to :generating shows thinking indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:state_change, :generating})

      assert render(view) =~ "Thinking..."
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
      assert render(view) =~ "Thinking..."

      payload = %{response: "Here is the answer.", citations: []}
      broadcast_to_view(view, {:response_ready, payload})

      html = render(view)
      assert html =~ "Here is the answer."
      assert html =~ "Cake"
      refute html =~ "Thinking..."
    end

    test ":response_ready with citations renders sources", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      citations = [
        %{new_index: 1, label: "Test Book", source_ref: "abc123", preview: "A preview snippet"}
      ]

      payload = %{response: "See [1].", citations: citations}
      broadcast_to_view(view, {:response_ready, payload})

      html = render(view)
      assert html =~ "Sources:"
      assert html =~ "Test Book"
      assert html =~ "A preview snippet"
    end

    test ":error shows a safe message without leaking the reason and returns to idle",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      broadcast_to_view(view, {:error, :some_failure})

      html = render(view)
      assert html =~ "something went wrong"
      refute html =~ "some_failure"
      refute html =~ "Thinking..."
    end
  end

  describe "selection panel interactions" do
    test "validate_selection updates form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      candidates = build_candidates()
      broadcast_to_view(view, {:candidates_ready, candidates})

      html =
        view
        |> form("form", selection_form: %{selected_doc_ids: ["ref-1"]})
        |> render_change()

      assert html =~ "Select documents to use"
    end
  end

  describe "conversation process crash" do
    test "DOWN message shows a safe message without leaking the crash reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      send(view.pid, {:DOWN, make_ref(), :process, self(), :boom})

      html = render(view)
      assert html =~ "ended unexpectedly"
      refute html =~ "boom"
    end
  end

  # --- Helpers ---

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
