defmodule Cake.ConversationIntegrationTest do
  @moduledoc """
  The full RAG loop through `Cake.Conversation` against a real search
  cluster (#249, tier 1): a real-index corpus of `Cake.Books.Chunk` rows
  hydrated through the Books GDS, deterministic Mox embeddings,
  `Req.Test`-scripted generation through the real `Cake.Generation.OpenAI`
  transport, and the real `Cake.Responses` pipeline. Every other
  `Conversation` test runs against `Cake.Support.FixtureGDS` and mocks;
  these are the only ones that verify chunk-map indices, citation
  resolution, and the PubSub events survive contact with real hit
  hydration.

  Runs with `mix test --only integration`. `async: false` so the Ecto
  sandbox is shared: the turn runs in a task under `Cake.TaskSupervisor`
  and hydrates hits from Postgres there.

  ## Corpus geometry

  Chunk `i` embeds on unit-vector axis `i`, so a query vector blended
  from axes 0 and 1 ranks chunk 0 first (cosine 0.8), chunk 1 second
  (0.6) and chunk 2 nowhere (0.0). After `Cake.Search.normalize_and_combine/1`
  chunk 2's relevance is exactly 0 and the `Prompt.prepare_context/2`
  floor (0.3) drops it, while chunk 1 keeps at least 0.375 (half its
  normalized cosine) whatever BM25 adds — so the context is exactly
  chunks 0 and 1, in that order, without tolerances.
  """

  use Cake.SearchIntegrationCase, async: false

  import Mox
  import Cake.ConversationIntegrationHelpers

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Citable
  alias Cake.Conversation
  alias Cake.Promptable
  alias Cake.Search.Provenance
  alias Cake.Search.Result

  setup :verify_on_exit!

  # No token of the question below appears in the third chunk, so its
  # BM25 contribution is zero and its backend score is the minimum.
  @pump_text "The RO-400 reverse osmosis unit is fitted with the P-100 booster pump."
  @warranty_text "Every P-100 booster pump carries a five-year limited warranty."
  @filter_text "Sediment prefilter cartridges should be replaced every six months."
  @question "Which booster pump is fitted in the RO-400?"
  @embedder "text-embedding-ada-002"

  # The three-chunk corpus above, seeded into the test's collection.
  defp seed_standard_corpus(%{collection: collection}) do
    corpus =
      seed_corpus!(collection, [
        %{text: @pump_text, axis: 0},
        %{text: @warranty_text, axis: 1},
        %{text: @filter_text, axis: 2}
      ])

    [pump, warranty, filter] = corpus.chunks
    %{corpus: corpus, pump: pump, warranty: warranty, filter: filter}
  end

  # A book with no chunks at all: every retrieval against it finds nothing.
  defp seed_empty_corpus(%{collection: collection}) do
    %{corpus: seed_corpus!(collection, [])}
  end

  defp expect_query_embedding(question, vector) do
    expect(Cake.Embeddings.Mock, :embed, fn :openai, %{input: ^question}, @embedder ->
      embedding_result(vector)
    end)
  end

  describe "autoask/2 end to end (plain path, decomposition: nil)" do
    setup :seed_standard_corpus

    test "real hits → dense indices → resolved citations → response-ready broadcast",
         %{collection: collection, corpus: corpus, pump: pump, warranty: warranty, filter: filter} do
      test_pid = self()
      expect_query_embedding(@question, blend_vector([{0, 0.8}, {1, 0.6}]))

      # The model cites the warranty chunk first, so renumbering has real
      # work to do: old [2] becomes new [1] and old [1] becomes new [2].
      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})
        "The unit carries a five-year warranty [2] on its P-100 booster pump [1]."
      end)

      pid = start_subscribed_conversation!(conversation_opts(corpus.gds))

      assert :ok = Conversation.autoask(pid, @question)

      assert_receive {:state_change, :generating}
      assert_receive {:response_ready, %{response: response, citations: citations}}
      assert_receive {:state_change, :idle}

      # Prompt.prepare_context assigned dense 1..N indices over the real
      # hits, in relevance order, and Prompt.build numbered the context.
      assert_receive {:prompt, [%{"role" => "system", "content" => system} | rest]}
      assert List.last(rest) == %{"role" => "user", "content" => @question}
      assert String.contains?(system, "[1] " <> Promptable.prompt_context(pump))
      assert String.contains?(system, "[2] " <> Promptable.prompt_context(warranty))
      refute String.contains?(system, @filter_text)
      refute String.contains?(system, "[3] Book:")

      # Responses.process resolved the markers against the real chunk map
      # and renumbered by first appearance.
      assert response ==
               "The unit carries a five-year warranty [1] on its P-100 booster pump [2]."

      assert [first, second] = citations
      assert %{new_index: 1, old_index: 2} = first
      assert %{new_index: 2, old_index: 1} = second
      assert_citation_from(first, warranty, corpus.book)
      assert_citation_from(second, pump, corpus.book)

      assert GenServer.call(pid, :chunk_map) == %{
               1 => Citable.metadata(pump),
               2 => Citable.metadata(warranty)
             }

      assert GenServer.call(pid, :citations) == citations

      # The cached retrieval is the scored, relevance-sorted list of real
      # Search.Result structs, every unit a Chunk with its book preloaded.
      results = GenServer.call(pid, :search_results)
      assert unit_ids(results) == [pump.id, warranty.id, filter.id]

      for %Result{} = result <- results do
        assert %Chunk{parsed_book: %ParsedBook{}} = result.retrieval_unit
        assert result.hit_source == :search
        assert result.index == collection
        assert is_float(result.backend_score)
        assert is_float(result.cosine_score)
        assert is_float(result.relevance_score)

        assert %Provenance{search_type: :hybrid, query_text: @question, decomposed: false} =
                 result.provenance
      end

      [top, middle, bottom] = results
      assert top.relevance_score == 1.0
      assert middle.relevance_score >= 0.375
      assert bottom.relevance_score == 0.0

      assert :sys.get_state(pid).state == :idle
    end
  end

  describe "manual flow: manualask/2 → candidates → select_docs/2" do
    setup :seed_standard_corpus

    test "candidates are the real hits, and generation sees only the chosen docs",
         %{corpus: corpus, pump: pump, warranty: warranty, filter: filter} do
      test_pid = self()
      expect_query_embedding(@question, blend_vector([{0, 0.8}, {1, 0.6}]))

      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})
        "Five years [1]."
      end)

      pid = start_subscribed_conversation!(conversation_opts(corpus.gds))

      assert :ok = Conversation.manualask(pid, @question)
      assert_receive {:state_change, :retrieving}
      assert_receive {:candidates_ready, candidates}
      assert_receive {:state_change, :awaiting_selection}

      # Every chunk the search surfaced, hydrated and relevance-sorted, is
      # offered — the relevance floor applies to auto mode, not to the
      # user's own pick.
      assert unit_ids(candidates) == [pump.id, warranty.id, filter.id]
      assert Enum.all?(candidates, &match?(%Result{retrieval_unit: %Chunk{}}, &1))
      assert :sys.get_state(pid).state == :awaiting_selection

      # Only the warranty chunk is selected: it becomes [1], and the pump
      # chunk — a better hit — never reaches the prompt.
      assert :ok = Conversation.select_docs(pid, [warranty.id])
      assert_receive {:state_change, :generating}
      assert_receive {:response_ready, %{response: "Five years [1].", citations: [citation]}}
      assert_receive {:state_change, :idle}

      assert_receive {:prompt, [%{"role" => "system", "content" => system} | _]}
      assert String.contains?(system, "[1] " <> Promptable.prompt_context(warranty))
      refute String.contains?(system, @pump_text)
      refute String.contains?(system, "[2] Book:")

      assert %{new_index: 1, old_index: 1} = citation
      assert_citation_from(citation, warranty, corpus.book)
      assert GenServer.call(pid, :chunk_map) == %{1 => Citable.metadata(warranty)}

      # The whole candidate list is what later turns reuse, not the pick.
      assert unit_ids(GenServer.call(pid, :search_results)) == [pump.id, warranty.id, filter.id]
    end
  end

  describe "cached retrieval across turns" do
    setup :seed_standard_corpus

    test "a follow-up turn reuses the first turn's hits without asking the cluster again",
         %{collection: collection, corpus: corpus, pump: pump, warranty: warranty} do
      test_pid = self()

      # Exactly one embed across both turns: a re-retrieval on turn two
      # would be an unexpected call and fail under Mox.
      expect_query_embedding(@question, blend_vector([{0, 0.8}, {1, 0.6}]))

      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})

        case List.last(messages) do
          %{"content" => @question} -> "It is the P-100 [1]."
          _follow_up -> "Five years [2]."
        end
      end)

      pid = start_subscribed_conversation!(conversation_opts(corpus.gds))
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: "It is the P-100 [1]."}}
      assert_receive {:prompt, _turn_one}

      searches_after_first = search_request_count!(collection)
      assert searches_after_first > searches_before

      follow_up = "And how long is its warranty?"
      assert :ok = Conversation.autoask(pid, follow_up)
      assert_receive {:response_ready, %{response: "Five years [1].", citations: [citation]}}
      assert_receive {:prompt, turn_two}

      # No search request reached the collection for the second turn...
      assert search_request_count!(collection) == searches_after_first

      # ...yet its prompt carries the cached context, freshly numbered,
      # plus the first exchange as history.
      [%{"role" => "system", "content" => system} | rest] = turn_two
      assert String.contains?(system, "[1] " <> Promptable.prompt_context(pump))
      assert String.contains?(system, "[2] " <> Promptable.prompt_context(warranty))

      assert rest == [
               %{"role" => "user", "content" => @question},
               %{"role" => "assistant", "content" => "It is the P-100 [1]."},
               %{"role" => "user", "content" => follow_up}
             ]

      assert_citation_from(citation, warranty, corpus.book)

      assert unit_ids(GenServer.call(pid, :search_results)) == [
               pump.id,
               warranty.id,
               filter_id(corpus)
             ]
    end
  end

  describe "empty first retrieval is a completed retrieval (#255, fixed in #264)" do
    setup :seed_empty_corpus

    test "decompose and embed run once across two turns; the second reuses the cached []",
         %{collection: collection, corpus: corpus} do
      test_pid = self()
      question = "Is there anything about the RO-400 at all?"

      # Exactly once each, across both turns.
      expect(Cake.Decomposition.Mock, :decompose, fn ^question, _opts ->
        {:ok, Cake.Decomposition.Result.new(question)}
      end)

      expect_query_embedding(question, blend_vector([{0, 1.0}]))

      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})
        "I could not find anything about that."
      end)

      pid =
        start_subscribed_conversation!(
          conversation_opts(corpus.gds, %{decomposition: Cake.Decomposition.Mock})
        )

      assert :ok = Conversation.autoask(pid, question)
      assert_receive {:response_ready, %{response: "I could not find anything about that."}}
      assert_receive {:prompt, [%{"role" => "system", "content" => no_context} | _]}
      assert no_context == Cake.Prompt.system_message_no_context()

      assert GenServer.call(pid, :search_results) == []
      assert :sys.get_state(pid).search_results == []
      searches_after_first = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, "Really nothing?")
      assert_receive {:response_ready, %{response: "I could not find anything about that."}}
      assert_receive {:prompt, [%{"role" => "system", "content" => ^no_context} | _]}

      assert search_request_count!(collection) == searches_after_first
      assert :sys.get_state(pid).search_results == []
    end
  end

  describe "citation hygiene" do
    setup :seed_standard_corpus

    test "a marker with no chunk behind it is dropped from the text and the citations",
         %{corpus: corpus, pump: pump} do
      expect_query_embedding(@question, blend_vector([{0, 0.8}, {1, 0.6}]))
      script_generation!(fn _messages -> "The P-100 [1], as noted [9]." end)

      pid = start_subscribed_conversation!(conversation_opts(corpus.gds))

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: response, citations: citations}}

      assert citation_markers(response) == [1]
      assert response == "The P-100 [1], as noted ."
      assert [%{new_index: 1, old_index: 1, id: id}] = citations
      assert id == pump.id
      refute Enum.any?(citations, &(&1.old_index == 9))
    end
  end

  defp filter_id(%{chunks: [_pump, _warranty, filter]}), do: filter.id

  # A citation record is the Citable metadata of the seeded chunk plus the
  # two indices; nothing invented, nothing dropped along the way.
  defp assert_citation_from(citation, %Chunk{} = chunk, %ParsedBook{} = book) do
    metadata = Citable.metadata(chunk)

    assert citation.id == chunk.id
    assert citation.label == metadata.label
    assert citation.preview == metadata.preview
    assert citation.source_ref == book.source_file_path
    assert citation.extras == metadata.extras

    assert Enum.sort(Map.keys(citation)) == [
             :extras,
             :id,
             :label,
             :new_index,
             :old_index,
             :preview,
             :source_ref
           ]
  end
end
