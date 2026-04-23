defmodule Cake.PromptTest do
  use ExUnit.Case, async: true

  defp scored_chunk(score, opts \\ []) do
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

    {chunk, %{relevance_score: score}}
  end

  describe "prepare_context/2" do
    test "filters chunks below relevance floor" do
      chunks = Enum.map([0.9, 0.7, 0.5, 0.2, 0.1], &scored_chunk/1)
      {indexed, quality} = Cake.Prompt.prepare_context(chunks, min_relevance: 0.3)
      assert length(indexed) == 3
      assert quality == :good
    end

    test "trims to chunk ceiling" do
      chunks = Enum.map(1..15, fn _ -> scored_chunk(0.8) end)
      {indexed, _quality} = Cake.Prompt.prepare_context(chunks, max_chunks: 10)
      assert length(indexed) == 10
    end

    test "relevance floor applies before chunk ceiling" do
      above = Enum.map(1..7, fn _ -> scored_chunk(0.8) end)
      below = Enum.map(1..8, fn _ -> scored_chunk(0.1) end)
      {indexed, _quality} = Cake.Prompt.prepare_context(above ++ below, max_chunks: 10, min_relevance: 0.3)
      assert length(indexed) == 7
    end

    test "all chunks below threshold returns :none" do
      chunks = Enum.map(1..5, fn _ -> scored_chunk(0.1) end)
      assert {[], :none} = Cake.Prompt.prepare_context(chunks, min_relevance: 0.3)
    end

    test "empty input returns :none" do
      assert {[], :none} = Cake.Prompt.prepare_context([])
    end

    test "indices are dense after filtering" do
      chunks = [scored_chunk(0.9), scored_chunk(0.1), scored_chunk(0.7), scored_chunk(0.05), scored_chunk(0.5)]
      {indexed, _quality} = Cake.Prompt.prepare_context(chunks, min_relevance: 0.3)
      indices = Enum.map(indexed, fn {idx, _} -> idx end)
      assert indices == [1, 2, 3]
    end

    test "uses default opts when none provided" do
      chunks = Enum.map(1..5, fn _ -> scored_chunk(0.5) end)
      {indexed, quality} = Cake.Prompt.prepare_context(chunks)
      assert quality == :good
      assert length(indexed) == 5
    end
  end

  describe "build/4" do
    test "first turn with good context" do
      indexed = [{1, scored_chunk(0.9)}, {2, scored_chunk(0.8)}]
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
      indexed = [{1, scored_chunk(0.9)}, {2, scored_chunk(0.8)}]
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
      indexed = [{1, scored_chunk(0.9)}]
      question = "New question?"
      history = ["first_q", "first_a", "second_q", "second_a"]
      messages = Cake.Prompt.build(indexed, question, history)

      user_messages = Enum.filter(messages, fn msg -> msg.role == "user" and msg.content != question end)

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
    test "basic formatting" do
      {chunk, scores} =
        scored_chunk(0.9,
          text: "Replace the filter every 6 months.",
          page_number: 42,
          section_title: "Maintenance",
          book_title: "RO-400 Manual"
        )

      result = Cake.Prompt.format_chunk({1, {chunk, scores}})
      assert String.contains?(result, "[1]")
      assert String.contains?(result, "Book: RO-400 Manual")
      assert String.contains?(result, "Page: 42")
      assert String.contains?(result, "Section: Maintenance")
      assert String.contains?(result, "Replace the filter every 6 months.")
    end

    test "nil section title renders as (none)" do
      {chunk, scores} = scored_chunk(0.9, section_title: nil)
      result = Cake.Prompt.format_chunk({1, {chunk, scores}})
      assert String.contains?(result, "Section: (none)")
    end

    test "multiline text is preserved" do
      text = "Line one.\nLine two.\nLine three."
      {chunk, scores} = scored_chunk(0.9, text: text)
      result = Cake.Prompt.format_chunk({1, {chunk, scores}})
      assert String.contains?(result, text)
    end
  end

  describe "system_message_with_context/1" do
    test "contains citation instructions" do
      message = Cake.Prompt.system_message_with_context(["[1] Book: X\n\nchunk text"])
      assert String.contains?(message, "[1]")
      assert String.contains?(message, "cite")
      assert String.contains?(message, "fabricate")
      assert String.contains?(message, "cannot be found") or String.contains?(message, "not in the context")
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
end
