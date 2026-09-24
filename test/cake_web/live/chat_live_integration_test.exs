defmodule CakeWeb.ChatLiveIntegrationTest do
  @moduledoc """
  `CakeWeb.ChatLive` over a real search cluster (#249, tier 1, item 7):
  mount starts a `Cake.Conversation` from the application config, a
  submitted question is embedded (Mox), searched for real, hydrated
  through the Books GDS, answered by `Req.Test`-scripted generation
  through the real OpenAI transport, and the response-ready broadcast
  comes back round through PubSub to render the answer and its sources.
  `CakeWeb.ChatLiveTest` covers the same UI with hand-built broadcasts;
  this is the only test in which the citations it renders were resolved
  against real hits.

  Runs with `mix test --only integration`. `async: false`: the
  conversation config `ChatLive` reads is global, as is the collection
  GDS's, and the Ecto sandbox must be shared with the LiveView and the
  turn task.

  ## Synchronizing on the round trip without sleeping

  The test subscribes to the conversation's topic alongside the view.
  `Cake.Conversation` broadcasts `{:response_ready, _}` and then
  `{:state_change, :idle}` as two separate broadcasts from one process,
  so by the time the test receives the second, the first is already in
  the view's mailbox — and `render/1`, a call to the view, is served
  after it. No `Process.sleep`, no polling.
  """

  use Cake.SearchIntegrationCase, async: false

  import Mox
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Cake.ConversationIntegrationHelpers

  alias Cake.Citable

  @endpoint CakeWeb.Endpoint

  setup :verify_on_exit!

  @pump_text "The RO-400 reverse osmosis unit is fitted with the P-100 booster pump."
  @warranty_text "Every P-100 booster pump carries a five-year limited warranty."
  @filter_text "Sediment prefilter cartridges should be replaced every six months."
  @question "Which booster pump is fitted in the RO-400?"
  @embedder "text-embedding-ada-002"

  setup %{collection: collection} do
    corpus =
      seed_corpus!(collection, [
        %{text: @pump_text, axis: 0},
        %{text: @warranty_text, axis: 1},
        %{text: @filter_text, axis: 2}
      ])

    configure_chat_conversation!(corpus.gds)

    conn = CakeWeb.ConnCase.log_in_user(build_conn(), Cake.AccountsFixtures.user_fixture())

    [pump, warranty, _filter] = corpus.chunks
    %{conn: conn, corpus: corpus, pump: pump, warranty: warranty}
  end

  defp expect_query_embedding(question, vector) do
    expect(Cake.Embeddings.Mock, :embed, fn :openai, %{input: ^question}, @embedder ->
      embedding_result(vector)
    end)
  end

  defp submit_question(view, question, mode) do
    view
    |> form("form", question_form: %{question: question, mode: mode})
    |> render_submit()
  end

  # What the view shows for a citation: `ChatLive` rewrites ", p. N" in
  # the label to ", PDF page N".
  defp rendered_label(chunk) do
    String.replace(Citable.metadata(chunk).label, ~r/, p\. (\d+)/, ", PDF page \\1")
  end

  describe "auto mode" do
    test "mount → submit → real retrieval → PubSub round trip → answer and sources rendered",
         %{conn: conn, corpus: corpus, pump: pump, warranty: warranty} do
      {:ok, view, _html} = live(conn, "/chat")
      _conversation = attach_to_chat_conversation!(view)

      expect_query_embedding(@question, blend_vector([{0, 0.8}, {1, 0.6}]))

      script_generation!(fn _messages ->
        "It is the P-100 booster pump [1], warranted five years [2]."
      end)

      # The user message renders on submit; the thinking indicator arrives
      # with the conversation's own :generating broadcast, asynchronously,
      # so it is not asserted here.
      assert submit_question(view, @question, "auto") =~ @question

      assert_receive {:response_ready, %{citations: [first, second]}}
      assert_receive {:state_change, :idle}
      assert first.id == pump.id
      assert second.id == warranty.id

      html = render(view)
      assert html =~ "It is the P-100 booster pump [1], warranted five years [2]."
      assert html =~ "Sources:"
      assert html =~ "[1] " <> rendered_label(pump)
      assert html =~ "[2] " <> rendered_label(warranty)
      assert html =~ "/books/download/" <> corpus.book.source_file_path
      assert html =~ Citable.metadata(pump).preview
      refute html =~ "Thinking..."
      assert html =~ "Ask a question..."
    end
  end

  describe "manual mode" do
    test "candidates from real hits are offered by document, and 'Use all' answers over them",
         %{conn: conn, corpus: corpus, pump: pump} do
      {:ok, view, _html} = live(conn, "/chat")
      _conversation = attach_to_chat_conversation!(view)

      expect_query_embedding(@question, blend_vector([{0, 0.8}, {1, 0.6}]))
      script_generation!(fn _messages -> "The P-100 [1]." end)

      submit_question(view, @question, "manual")

      assert_receive {:candidates_ready, candidates}
      assert_receive {:state_change, :awaiting_selection}
      assert length(candidates) == 3

      # One book, three chunks: a single document card.
      html = render(view)
      assert html =~ "Select documents to use"
      assert html =~ "1 found"
      assert html =~ corpus.book.title
      assert html =~ "3 chunks"
      assert html =~ "PDF pages 1-3"

      view |> element("button[phx-click=use_all]") |> render_click()

      assert_receive {:response_ready, %{citations: [citation]}}
      assert_receive {:state_change, :idle}
      assert citation.id == pump.id

      answered = render(view)
      assert answered =~ "The P-100 [1]."
      assert answered =~ "[1] " <> rendered_label(pump)
      refute answered =~ "Select documents to use"
    end
  end
end
