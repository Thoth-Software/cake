defmodule Cake.ConversationDecompositionIntegrationTest do
  @moduledoc """
  The four decomposition strategies through `Cake.Conversation` against a
  real search cluster (#249, tier 1, item 5): a Mox decomposition
  collaborator marks the strategy, every sub-question, follow-up or
  retrieval query is embedded (Mox, one unit vector per question) and
  searched for real, hits hydrate through the Books GDS, and the real
  `Cake.Responses` resolves the final citations against the merged
  context. Generation is scripted — through `Req.Test` and the real
  OpenAI transport for the planned strategies, through
  `Cake.Generation.Mock` for the two interleaved ones — and never
  asserted on as prose.

  Runs with `mix test --only integration`; `async: false` for the shared
  Ecto sandbox and the config-backed collection GDS.

  ## Corpus geometry

  Chunk `i` embeds on unit-vector axis `i`, so a question embedded on
  axis `i` scores chunk `i` at cosine 1.0 and every other chunk at 0.0:
  chunk `i` is that search's top hit and its `[1]`, whatever BM25 adds
  for the words the question shares with the other chunks. The filter
  chunk shares no word with any question, so its backend score is the
  minimum and its relevance exactly 0.0 — below the floor in every
  search. Across searches, `merge_decomposed_results/1` keeps each chunk
  once, from the search that scored it highest, so each chunk's
  provenance names the question that surfaced it.
  """

  use Cake.SearchIntegrationCase, async: false

  import Mox
  import Cake.ConversationIntegrationHelpers

  alias Cake.Conversation
  alias Cake.Promptable
  alias Cake.Search.Result

  setup :verify_on_exit!

  @pump_text "The RO-400 reverse osmosis unit is fitted with the P-100 booster pump."
  @warranty_text "Every P-100 booster pump carries a five-year limited warranty."
  @filter_text "Sediment prefilter cartridges should be replaced every six months."
  @embedder "text-embedding-ada-002"

  @question "What is the warranty on the pump used in the RO-400?"
  @pump_question "Which pump does the RO-400 use?"
  @warranty_question "What is the warranty on that pump?"

  setup %{collection: collection} do
    corpus =
      seed_corpus!(collection, [
        %{text: @pump_text, axis: 0},
        %{text: @warranty_text, axis: 1},
        %{text: @filter_text, axis: 2}
      ])

    [pump, warranty, filter] = corpus.chunks
    %{corpus: corpus, pump: pump, warranty: warranty, filter: filter}
  end

  # Each question embeds on its own axis: the pump question on the pump
  # chunk's, the warranty question on the warranty chunk's. Announces the
  # embed to the test so resolution order can be asserted.
  defp expect_embeddings(count) do
    test_pid = self()

    expect(Cake.Embeddings.Mock, :embed, count, fn :openai, %{input: input}, @embedder ->
      send(test_pid, {:embedded, input})
      embedding_result(unit_vector(axis_for(input)))
    end)
  end

  defp axis_for(@pump_question), do: 0
  defp axis_for(@warranty_question), do: 1

  defp decomposing_opts(corpus, overrides \\ %{}) do
    conversation_opts(corpus.gds, Map.merge(%{decomposition: Cake.Decomposition.Mock}, overrides))
  end

  defp provenance_by_id(pid) do
    pid
    |> GenServer.call(:search_results)
    |> Map.new(fn %Result{} = result -> {hd(unit_ids([result])), result.provenance} end)
  end

  describe "(a) flat DAG" do
    test "one real search per sub-question, merged and deduplicated, provenance stamped",
         %{collection: collection, corpus: corpus, pump: pump, warranty: warranty, filter: filter} do
      test_pid = self()

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, Cake.Decomposition.Result.new(@question, [@pump_question, @warranty_question])}
      end)

      expect_embeddings(2)

      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})
        "The P-100 [1] has a five-year warranty [2]."
      end)

      pid = start_subscribed_conversation!(decomposing_opts(corpus))
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: response, citations: citations}}

      # Both sub-questions were embedded and each ran one search.
      assert_receive {:embedded, first}
      assert_receive {:embedded, second}
      assert Enum.sort([first, second]) == Enum.sort([@pump_question, @warranty_question])
      assert search_request_count!(collection) - searches_before == 2

      # The merged context is one chunk per sub-question, each numbered
      # once; the filter chunk scored 0.0 in both searches and is absent.
      assert_receive {:prompt, [%{"role" => "system", "content" => system} | rest]}
      assert List.last(rest) == %{"role" => "user", "content" => @question}
      assert String.contains?(system, Promptable.prompt_context(pump))
      assert String.contains?(system, Promptable.prompt_context(warranty))
      refute String.contains?(system, @filter_text)
      refute String.contains?(system, "[3] Book:")

      assert citation_markers(response) == [1, 2]
      assert Enum.sort(Enum.map(citations, & &1.id)) == Enum.sort([pump.id, warranty.id])

      # Every merged result traces back to the sub-question that scored it
      # highest, by index into the decomposition's question_index.
      provenance = provenance_by_id(pid)
      assert map_size(provenance) == 3

      assert %{decomposed: true, original_query: @question, sub_question_index: 0} =
               provenance[pump.id]

      assert %{decomposed: true, original_query: @question, sub_question_index: 1} =
               provenance[warranty.id]

      assert %{decomposed: true, original_query: @question} = provenance[filter.id]
    end
  end

  describe "(b) sequential DAG (least-to-most)" do
    # Positional order is warranty-first; the dependency edge forces the
    # pump sub-question to resolve first.
    @entries [
      %{question: @warranty_question, depends_on: [1]},
      %{question: @pump_question, depends_on: []}
    ]

    test "resolves in topological order over the real index, folding stripped answers forward",
         %{collection: collection, corpus: corpus, pump: pump, warranty: warranty} do
      test_pid = self()

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, Cake.Decomposition.Result.new(@question, @entries)}
      end)

      expect_embeddings(2)

      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})

        case List.last(messages)["content"] do
          @pump_question -> "It uses the P-100 booster pump [1]."
          @warranty_question -> "Five years [1]."
          @question -> "The P-100's warranty is five years [1][2]."
        end
      end)

      pid = start_subscribed_conversation!(decomposing_opts(corpus))
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: response, citations: citations}}

      # Dependency order, one search each.
      assert_receive {:embedded, @pump_question}
      assert_receive {:embedded, @warranty_question}
      assert search_request_count!(collection) - searches_before == 2

      # Step 1: the pump question over the pump chunk, no prior answers.
      assert_receive {:prompt, step_one}
      assert List.last(step_one)["content"] == @pump_question
      assert String.contains?(prompt_text(step_one), "[1] " <> Promptable.prompt_context(pump))
      refute String.contains?(prompt_text(step_one), "Previously answered")

      # Step 2: the warranty question over the warranty chunk, with the
      # pump pair folded in and its stale [1] stripped.
      assert_receive {:prompt, step_two}
      assert List.last(step_two)["content"] == @warranty_question
      step_two_text = prompt_text(step_two)
      assert String.contains?(step_two_text, "[1] " <> Promptable.prompt_context(warranty))

      assert String.contains?(
               step_two_text,
               "Q: #{@pump_question}\nA: It uses the P-100 booster pump."
             )

      refute String.contains?(step_two_text, "booster pump [1]")

      # Final synthesis: the original question over the merged context
      # plus both accumulated answers, markers stripped.
      assert_receive {:prompt, final}
      assert List.last(final)["content"] == @question
      final_text = prompt_text(final)
      assert String.contains?(final_text, Promptable.prompt_context(pump))
      assert String.contains?(final_text, Promptable.prompt_context(warranty))
      assert String.contains?(final_text, "A: It uses the P-100 booster pump.")
      assert String.contains?(final_text, "Q: #{@warranty_question}\nA: Five years.")
      refute String.contains?(final_text, "Five years [1]")

      # The final markers cite the merged numbering.
      assert citation_markers(response) == [1, 2]
      assert Enum.sort(Enum.map(citations, & &1.id)) == Enum.sort([pump.id, warranty.id])

      # Provenance names the positional sub-question index, not the
      # resolution order.
      provenance = provenance_by_id(pid)
      assert %{decomposed: true, sub_question_index: 1} = provenance[pump.id]
      assert %{decomposed: true, sub_question_index: 0} = provenance[warranty.id]
    end

    test "a zero :max_context_tokens budget keeps prior answers out of every prompt",
         %{corpus: corpus} do
      test_pid = self()

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, Cake.Decomposition.Result.new(@question, @entries)}
      end)

      expect_embeddings(2)

      script_generation!(fn messages ->
        send(test_pid, {:prompt, messages})

        case List.last(messages)["content"] do
          @pump_question -> "It uses the P-100 booster pump."
          @warranty_question -> "Five years."
          @question -> "Five years [1]."
        end
      end)

      pid = start_subscribed_conversation!(decomposing_opts(corpus, %{max_context_tokens: 0}))

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: "Five years [1]."}}

      assert_receive {:prompt, _step_one}
      assert_receive {:prompt, step_two}
      assert_receive {:prompt, final}

      refute String.contains?(prompt_text(step_two), "It uses the P-100 booster pump.")
      refute String.contains?(prompt_text(final), "It uses the P-100 booster pump.")
      refute String.contains?(prompt_text(final), "Previously answered")
    end
  end

  describe "(c) self-ask" do
    setup %{corpus: corpus} do
      %{opts: decomposing_opts(corpus, %{generation: Cake.Generation.Mock})}
    end

    test "resolves each follow-up against the real index and stops on the final-answer marker",
         %{collection: collection, opts: opts, pump: pump} do
      test_pid = self()

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, self_ask_result(@question)}
      end)

      expect_embeddings(1)

      # Driver → follow-up; intermediate → answer over the pump chunk;
      # driver with the pair folded in → final answer. The final answer's
      # stale marker must not survive into citation resolution.
      expect(Cake.Generation.Mock, :complete, 3, fn messages, _model, _opts ->
        send(test_pid, {:prompt, messages})

        text =
          cond do
            List.last(messages).content == @pump_question ->
              "It uses the P-100 [1]."

            String.contains?(prompt_text(messages), "It uses the P-100.") ->
              "So the final answer is: The P-100 [1]."

            true ->
              "I need more information.\nFollow up: #{@pump_question}"
          end

        {:ok, %{text: text, usage: %{}}}
      end)

      pid = start_subscribed_conversation!(opts)
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: "The P-100.", citations: []}}

      assert_receive {:embedded, @pump_question}
      assert search_request_count!(collection) - searches_before == 1

      assert_receive {:prompt, driver_one}
      assert driver_prompt?(driver_one)
      assert List.last(driver_one).content == @question

      assert_receive {:prompt, intermediate}
      refute driver_prompt?(intermediate)
      assert List.last(intermediate).content == @pump_question

      assert String.contains?(
               prompt_text(intermediate),
               "[1] " <> Promptable.prompt_context(pump)
             )

      assert_receive {:prompt, driver_two}
      assert driver_prompt?(driver_two)

      assert String.contains?(
               prompt_text(driver_two),
               "Q: #{@pump_question}\nA: It uses the P-100."
             )

      # The merged context is the follow-up's hits, indexed by follow-up
      # round; a self-ask Result has no question_index to point into.
      provenance = provenance_by_id(pid)

      assert %{decomposed: true, original_query: @question, sub_question_index: 0} =
               provenance[pump.id]

      assert Enum.all?(provenance, fn {_id, p} -> p.sub_question_index == 0 end)
    end

    test "stops at :max_self_ask_iterations and synthesizes over the merged context",
         %{collection: collection, opts: opts, pump: pump, warranty: warranty} do
      test_pid = self()

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, self_ask_result(@question)}
      end)

      expect_embeddings(2)

      # The driver never emits the final marker: round 0 asks about the
      # pump, round 1 about the warranty, then the cap ends it and one
      # plain synthesis over the merged, numbered context follows.
      expect(Cake.Generation.Mock, :complete, 5, fn messages, _model, _opts ->
        send(test_pid, {:prompt, messages})
        text = prompt_text(messages)

        answer =
          cond do
            driver_prompt?(messages) and String.contains?(text, "Q: #{@pump_question}") ->
              "Follow up: #{@warranty_question}"

            driver_prompt?(messages) ->
              "Follow up: #{@pump_question}"

            List.last(messages).content == @pump_question ->
              "It uses the P-100."

            List.last(messages).content == @warranty_question ->
              "Five years."

            true ->
              "Five years on the P-100 [1][2]."
          end

        {:ok, %{text: answer, usage: %{}}}
      end)

      pid = start_subscribed_conversation!(Map.put(opts, :max_self_ask_iterations, 2))
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: response, citations: citations}}

      assert_receive {:embedded, @pump_question}
      assert_receive {:embedded, @warranty_question}
      assert search_request_count!(collection) - searches_before == 2

      # driver, intermediate, driver, intermediate, synthesis
      for _ <- 1..4, do: assert_receive({:prompt, _})
      assert_receive {:prompt, synthesis}
      refute driver_prompt?(synthesis)
      assert List.last(synthesis).content == @question
      assert String.contains?(prompt_text(synthesis), Promptable.prompt_context(pump))
      assert String.contains?(prompt_text(synthesis), Promptable.prompt_context(warranty))
      assert String.contains?(prompt_text(synthesis), "A: It uses the P-100.")

      assert citation_markers(response) == [1, 2]
      assert Enum.sort(Enum.map(citations, & &1.id)) == Enum.sort([pump.id, warranty.id])

      provenance = provenance_by_id(pid)
      assert %{decomposed: true, sub_question_index: 0} = provenance[pump.id]
      assert %{decomposed: true, sub_question_index: 1} = provenance[warranty.id]
    end
  end

  describe "(d) IRCoT" do
    setup %{corpus: corpus} do
      %{opts: decomposing_opts(corpus, %{generation: Cake.Generation.Mock})}
    end

    test "retrieves once per reasoning step against the real index and stops on a null query",
         %{collection: collection, opts: opts, pump: pump} do
      test_pid = self()
      reasoning_one = "I need to identify which pump the RO-400 uses."
      final_reasoning = "The P-100 pump carries a five-year warranty."

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, ircot_result(@question)}
      end)

      expect_embeddings(1)

      expect(Cake.Generation.Mock, :complete_json, 2, fn messages, _model, generation_opts ->
        send(test_pid, {:step, messages, generation_opts})

        parsed =
          if String.contains?(prompt_text(messages), reasoning_one) do
            %{"reasoning" => final_reasoning, "retrieval_query" => nil}
          else
            %{"reasoning" => reasoning_one, "retrieval_query" => @pump_question}
          end

        {:ok, %{parsed: parsed}}
      end)

      pid = start_subscribed_conversation!(opts)
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: ^final_reasoning, citations: []}}

      assert_receive {:embedded, @pump_question}
      assert search_request_count!(collection) - searches_before == 1

      assert_receive {:step, step_one, step_one_opts}
      assert Keyword.fetch!(step_one_opts, :schema) == Cake.Prompt.ircot_schema()
      assert List.last(step_one).content == @question
      refute String.contains?(prompt_text(step_one), @pump_text)

      # Step 2 carries step 1's reasoning and the pump chunk its query
      # surfaced — unnumbered, so no marker can point at it.
      assert_receive {:step, step_two, _opts}
      step_two_text = prompt_text(step_two)
      assert String.contains?(step_two_text, reasoning_one)
      assert String.contains?(step_two_text, Promptable.prompt_context(pump))
      refute String.contains?(step_two_text, "[1] " <> Promptable.prompt_context(pump))

      provenance = provenance_by_id(pid)

      assert %{
               decomposed: true,
               original_query: @question,
               sub_question_index: 0,
               query_text: @pump_question
             } =
               provenance[pump.id]
    end

    test "stops at :max_ircot_iterations and synthesizes over the merged context",
         %{collection: collection, opts: opts, pump: pump, warranty: warranty} do
      test_pid = self()

      expect(Cake.Decomposition.Mock, :decompose, fn @question, _opts ->
        {:ok, ircot_result(@question)}
      end)

      expect_embeddings(2)

      # Always wants more: step 1 asks for the pump, step 2 for the
      # warranty, and the cap of 2 ends the loop.
      expect(Cake.Generation.Mock, :complete_json, 2, fn messages, _model, _opts ->
        parsed =
          if String.contains?(prompt_text(messages), "step one") do
            %{"reasoning" => "step two", "retrieval_query" => @warranty_question}
          else
            %{"reasoning" => "step one", "retrieval_query" => @pump_question}
          end

        {:ok, %{parsed: parsed}}
      end)

      # Cap exhaustion synthesizes with a plain completion over the
      # merged, numbered context.
      expect(Cake.Generation.Mock, :complete, fn messages, _model, _opts ->
        send(test_pid, {:synthesis, messages})
        {:ok, %{text: "Five years on the P-100 [1][2].", usage: %{}}}
      end)

      pid = start_subscribed_conversation!(Map.put(opts, :max_ircot_iterations, 2))
      searches_before = search_request_count!(collection)

      assert :ok = Conversation.autoask(pid, @question)
      assert_receive {:response_ready, %{response: response, citations: citations}}

      assert_receive {:embedded, @pump_question}
      assert_receive {:embedded, @warranty_question}
      assert search_request_count!(collection) - searches_before == 2

      assert_receive {:synthesis, synthesis}
      assert List.last(synthesis).content == @question
      synthesis_text = prompt_text(synthesis)
      assert String.contains?(synthesis_text, Promptable.prompt_context(pump))
      assert String.contains?(synthesis_text, Promptable.prompt_context(warranty))
      refute String.contains?(synthesis_text, ~s("retrieval_query"))

      assert citation_markers(response) == [1, 2]
      assert Enum.sort(Enum.map(citations, & &1.id)) == Enum.sort([pump.id, warranty.id])

      provenance = provenance_by_id(pid)
      assert %{decomposed: true, sub_question_index: 0} = provenance[pump.id]
      assert %{decomposed: true, sub_question_index: 1} = provenance[warranty.id]
    end
  end
end
