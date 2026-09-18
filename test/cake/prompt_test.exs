defmodule Cake.PromptTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Provenance
  alias Cake.Search.Result

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  # Red phase: routed through apply/3 so the suite compiles before
  # estimate_tokens/1 exists.
  defp pair_cost({question, answer}) do
    apply(Cake.Prompt, :estimate_tokens, [question]) +
      apply(Cake.Prompt, :estimate_tokens, [answer])
  end

  defp scored_result(score, opts \\ []) do
    chunk = %Cake.Books.Chunk{
      text: Keyword.get(opts, :text, "Chunk text at score #{score}"),
      page_number: Keyword.get(opts, :page_number, 1),
      section_title: Keyword.get(opts, :section_title, "Section"),
      chunk_index: Keyword.get(opts, :chunk_index, 0),
      word_count: 10,
      char_count: 50,
      parsed_book: %Cake.Books.ParsedBook{
        title: Keyword.get(opts, :book_title, "Test Book"),
        source_file_path: "/path/to/book.pdf"
      }
    }

    %Result{
      retrieval_unit: chunk,
      relevance_score: score,
      hit_source: :search,
      index: "test_index",
      provenance: test_provenance()
    }
  end

  describe "prepare_context/2" do
    test "filters chunks below relevance floor" do
      chunks = Enum.map([0.9, 0.7, 0.5, 0.2, 0.1], &scored_result/1)
      {indexed, quality} = Cake.Prompt.prepare_context(chunks, min_relevance: 0.3)
      assert length(indexed) == 3
      assert quality == :good
    end

    test "trims to chunk ceiling" do
      chunks = Enum.map(1..15, fn _ -> scored_result(0.8) end)
      {indexed, _quality} = Cake.Prompt.prepare_context(chunks, max_chunks: 10)
      assert length(indexed) == 10
    end

    test "relevance floor applies before chunk ceiling" do
      above = Enum.map(1..7, fn _ -> scored_result(0.8) end)
      below = Enum.map(1..8, fn _ -> scored_result(0.1) end)

      {indexed, _quality} =
        Cake.Prompt.prepare_context(above ++ below, max_chunks: 10, min_relevance: 0.3)

      assert length(indexed) == 7
    end

    test "all chunks below threshold returns :none" do
      chunks = Enum.map(1..5, fn _ -> scored_result(0.1) end)
      assert {[], :none} = Cake.Prompt.prepare_context(chunks, min_relevance: 0.3)
    end

    test "empty input returns :none" do
      assert {[], :none} = Cake.Prompt.prepare_context([])
    end

    test "indices are dense after filtering" do
      chunks = [
        scored_result(0.9),
        scored_result(0.1),
        scored_result(0.7),
        scored_result(0.05),
        scored_result(0.5)
      ]

      {indexed, _quality} = Cake.Prompt.prepare_context(chunks, min_relevance: 0.3)
      indices = Enum.map(indexed, fn {idx, _} -> idx end)
      assert indices == [1, 2, 3]
    end

    test "uses default opts when none provided" do
      chunks = Enum.map(1..5, fn _ -> scored_result(0.5) end)
      {indexed, quality} = Cake.Prompt.prepare_context(chunks)
      assert quality == :good
      assert length(indexed) == 5
    end
  end

  describe "build/4" do
    test "first turn with good context" do
      indexed = [{1, scored_result(0.9)}, {2, scored_result(0.8)}]
      messages = Cake.Prompt.build(indexed, "What is the flow rate?", [])
      assert length(messages) == 2
      [system_msg, user_msg] = messages
      assert system_msg.role == "system"
      assert String.contains?(system_msg.content, "[1]")
      assert String.contains?(system_msg.content, "[2]")
      assert String.contains?(system_msg.content, "cite")
      assert user_msg.role == "user"
      assert user_msg.content == "What is the flow rate?"
    end

    test "first turn with no context (Case B)" do
      messages = Cake.Prompt.build([], "What is the flow rate?", [])
      assert length(messages) == 2
      [system_msg, user_msg] = messages
      assert system_msg.role == "system"
      refute String.contains?(system_msg.content, "[1]")
      assert String.contains?(system_msg.content, "could not find")
      assert user_msg.role == "user"
      assert user_msg.content == "What is the flow rate?"
    end

    test "subsequent turn with good context includes history" do
      indexed = [{1, scored_result(0.9)}, {2, scored_result(0.8)}]
      history = ["q1", "a1", "q2", "a2"]
      messages = Cake.Prompt.build(indexed, "New question?", history)
      assert length(messages) == 6
      roles = Enum.map(messages, & &1.role)
      assert roles == ["system", "user", "assistant", "user", "assistant", "user"]
      assert List.last(messages).content == "New question?"
    end

    test "subsequent turn with no context" do
      history = ["q1", "a1"]
      messages = Cake.Prompt.build([], "New question?", history)
      assert length(messages) == 4
      [system_msg | _rest] = messages
      assert system_msg.role == "system"
      assert String.contains?(system_msg.content, "could not find")
      assert List.last(messages).content == "New question?"
    end

    test "history messages are in chronological order" do
      indexed = [{1, scored_result(0.9)}]
      question = "New question?"
      history = ["first_q", "first_a", "second_q", "second_a"]
      messages = Cake.Prompt.build(indexed, question, history)

      user_messages =
        Enum.filter(messages, fn msg -> msg.role == "user" and msg.content != question end)

      [first_user | rest] = user_messages
      assert first_user.content == "first_q"
      assert hd(rest).content == "second_q"
    end
  end

  describe "history_messages/1" do
    test "at truncation boundary" do
      history = Enum.flat_map(1..5, fn i -> ["q#{i}", "a#{i}"] end)
      messages = Cake.Prompt.history_messages(history)
      assert length(messages) == 10
    end

    test "truncates above boundary" do
      history = Enum.flat_map(1..8, fn i -> ["q#{i}", "a#{i}"] end)
      messages = Cake.Prompt.history_messages(history)
      assert length(messages) == 10
      user_messages = Enum.filter(messages, &(&1.role == "user"))
      assert hd(user_messages).content == "q4"
    end

    test "below boundary returns all" do
      history = Enum.flat_map(1..2, fn i -> ["q#{i}", "a#{i}"] end)
      messages = Cake.Prompt.history_messages(history)
      assert length(messages) == 4
    end

    test "empty history returns empty list" do
      assert [] = Cake.Prompt.history_messages([])
    end

    test "odd-length history drops trailing unpaired question" do
      messages = Cake.Prompt.history_messages(["q1", "a1", "q2"])
      assert length(messages) == 2
    end
  end

  describe "format_chunk/1" do
    test "prepends [N] to Cake.Promptable.prompt_context/1" do
      result =
        scored_result(0.9,
          text: "Replace the filter every 6 months.",
          page_number: 42,
          section_title: "Maintenance",
          book_title: "RO-400 Manual"
        )

      assert Cake.Prompt.format_chunk({3, result}) ==
               "[3] " <> Cake.Promptable.prompt_context(result.retrieval_unit)
    end

    test "delegates nil-section-title rendering to Promptable" do
      result = scored_result(0.9, section_title: nil)

      assert Cake.Prompt.format_chunk({1, result}) ==
               "[1] " <> Cake.Promptable.prompt_context(result.retrieval_unit)
    end

    test "works polymorphically for any Promptable (ParsedDocument)" do
      doc = %Cake.Documents.ParsedDocument{
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: "Returns a list where each element is the result of invoking fun..."
      }

      result = %Result{
        retrieval_unit: doc,
        relevance_score: 0.9,
        hit_source: :search,
        index: "test_index",
        provenance: test_provenance()
      }

      assert Cake.Prompt.format_chunk({1, result}) ==
               "[1] " <> Cake.Promptable.prompt_context(doc)
    end
  end

  describe "system_message_with_context/1" do
    test "contains citation instructions" do
      message = Cake.Prompt.system_message_with_context(["[1] Book: X\n\nchunk text"])
      assert String.contains?(message, "[1]")
      assert String.contains?(message, "cite")
      assert String.contains?(message, "fabricate")

      assert String.contains?(message, "cannot be found") or
               String.contains?(message, "not in the context")
    end

    test "contains the context block" do
      message = Cake.Prompt.system_message_with_context(["[1] Book: X\n\nchunk text"])
      assert String.contains?(message, "[1] Book: X")
      assert String.contains?(message, "chunk text")
    end

    test "does not contain no-context language" do
      message = Cake.Prompt.system_message_with_context(["[1] Book: X\n\nchunk text"])
      refute String.contains?(message, "could not find")
    end
  end

  describe "system_message_no_context/0" do
    test "contains refusal language" do
      message = Cake.Prompt.system_message_no_context()
      assert String.contains?(message, "could not find")
      assert String.contains?(message, "fabricate") or String.contains?(message, "make up")
    end

    test "does not contain a context block" do
      message = Cake.Prompt.system_message_no_context()
      refute String.contains?(message, "[1]")
    end
  end

  describe "decomposition_prompt/1" do
    test "returns a system message followed by the question as the user message" do
      question = "How does the RO-400 filter compare to the RO-500?"

      assert [%{role: "system", content: system}, %{role: "user", content: ^question}] =
               Cake.Prompt.decomposition_prompt(question)

      assert String.contains?(system, "JSON")
    end

    test "system prompt documents the atomic JSON shape" do
      [%{role: "system", content: system} | _] = Cake.Prompt.decomposition_prompt("q")

      assert String.contains?(system, ~s({"atomic": true}))
    end

    test "system prompt documents the decomposed JSON shape" do
      [%{role: "system", content: system} | _] = Cake.Prompt.decomposition_prompt("q")

      assert String.contains?(system, ~s("sub_questions"))
    end
  end

  describe "estimate_tokens/1" do
    # Red phase: apply/3 keeps the suite compiling before the functions
    # exist — literal calls would trip --warnings-as-errors.
    test "approximates four characters per token, rounding up" do
      assert apply(Cake.Prompt, :estimate_tokens, [""]) == 0
      assert apply(Cake.Prompt, :estimate_tokens, ["abcd"]) == 1
      assert apply(Cake.Prompt, :estimate_tokens, ["abcde"]) == 2
      assert apply(Cake.Prompt, :estimate_tokens, ["abcdefgh"]) == 2
    end
  end

  describe "fit_answer_pairs/2" do
    test "a generous ceiling keeps every pair" do
      pairs = [{"q-old", "a-old"}, {"q-new", "a-new"}]

      assert apply(Cake.Prompt, :fit_answer_pairs, [pairs, 1_000_000]) == pairs
    end

    test "a zero ceiling keeps nothing" do
      pairs = [{"q-old", "a-old"}, {"q-new", "a-new"}]

      assert apply(Cake.Prompt, :fit_answer_pairs, [pairs, 0]) == []
    end

    test "drops the oldest pairs first when the ceiling is hit" do
      oldest = {"first sub-question asked", "the very first intermediate answer"}
      newest = {"last sub-question", "newest answer"}
      budget = pair_cost(newest)

      assert apply(Cake.Prompt, :fit_answer_pairs, [[oldest, newest], budget]) == [newest]
    end
  end

  describe "build_with_prior_answers/5" do
    test "folds kept prior answers into the system message ahead of the current question" do
      indexed = [{1, scored_result(0.9)}]
      pairs = [{"Which pump does the RO-400 use?", "The RO-400 uses the P-100 pump."}]
      question = "What is the warranty on that pump?"

      messages =
        apply(Cake.Prompt, :build_with_prior_answers, [
          indexed,
          question,
          pairs,
          [],
          [max_context_tokens: 1_000_000]
        ])

      [%{role: "system", content: system} | _rest] = messages

      assert String.contains?(system, "Which pump does the RO-400 use?")
      assert String.contains?(system, "The RO-400 uses the P-100 pump.")
      # The retrieved-context block is still present alongside the answers.
      assert String.contains?(system, "[1]")

      assert %{role: "user", content: ^question} = List.last(messages)
    end

    test "with no prior answers it matches build/4 exactly" do
      indexed = [{1, scored_result(0.9)}]
      question = "What is the flow rate?"
      history = ["q1", "a1"]

      assert apply(Cake.Prompt, :build_with_prior_answers, [
               indexed,
               question,
               [],
               history,
               [max_context_tokens: 1_000_000]
             ]) == Cake.Prompt.build(indexed, question, history)
    end

    test "evicts the oldest pair when the ceiling only fits the newest" do
      oldest = {"first sub-question asked", "the very first intermediate answer"}
      newest = {"last sub-question", "newest answer"}
      budget = pair_cost(newest)

      [%{role: "system", content: system} | _] =
        apply(Cake.Prompt, :build_with_prior_answers, [
          [{1, scored_result(0.9)}],
          "final?",
          [oldest, newest],
          [],
          [max_context_tokens: budget]
        ])

      refute String.contains?(system, "the very first intermediate answer")
      assert String.contains?(system, "newest answer")
    end

    test "a zero ceiling produces the plain build/4 prompt" do
      indexed = [{1, scored_result(0.9)}]
      pairs = [{"q-old", "a-old"}, {"q-new", "a-new"}]

      assert apply(Cake.Prompt, :build_with_prior_answers, [
               indexed,
               "final?",
               pairs,
               [],
               [max_context_tokens: 0]
             ]) == Cake.Prompt.build(indexed, "final?", [])
    end
  end
end
