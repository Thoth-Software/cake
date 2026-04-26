defmodule Cake.Prompt do
  @moduledoc """
  Prompt-building and prompt-engineering for the conversation layer.

  Receives scored chunks from Search, filters by relevance floor and chunk
  ceiling, assigns dense 1..N indices, formats chunks into a numbered context
  block, integrates conversation history, and returns the messages list for
  the LLM.
  """

  @type indexed_chunk :: {pos_integer(), Cake.Search.scored_result()}
  @type context_quality :: :good | :none
  @type message :: %{role: String.t(), content: String.t()}

  @default_max_chunks 10
  @default_min_relevance 0.3
  @max_history_exchanges 5

  @spec prepare_context([Cake.Search.scored_result()], keyword()) ::
          {[indexed_chunk()], context_quality()}
  def prepare_context(scored_chunks, opts \\ []) do
    max_chunks = Keyword.get(opts, :max_chunks, @default_max_chunks)
    min_relevance = Keyword.get(opts, :min_relevance, @default_min_relevance)

    indexed =
      scored_chunks
      |> Enum.filter(fn {_chunk, %{relevance_score: score}} -> score >= min_relevance end)
      |> Enum.take(max_chunks)
      |> Enum.with_index(1)
      |> Enum.map(fn {scored_chunk, idx} -> {idx, scored_chunk} end)

    context_quality = if indexed == [], do: :none, else: :good
    {indexed, context_quality}
  end

  @spec build([indexed_chunk()], String.t(), [String.t()], keyword()) :: [message()]
  def build(indexed_chunks, question, history, opts \\ [])

  def build([], question, history, _opts) do
    [%{role: "system", content: system_message_no_context()}]
    |> Kernel.++(history_messages(history))
    |> Kernel.++([%{role: "user", content: question}])
  end

  def build(indexed_chunks, question, history, _opts) do
    formatted = Enum.map(indexed_chunks, &format_chunk/1)

    [%{role: "system", content: system_message_with_context(formatted)}]
    |> Kernel.++(history_messages(history))
    |> Kernel.++([%{role: "user", content: question}])
  end

  @spec history_messages([String.t()]) :: [message()]
  def history_messages(history) do
    history
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.take(-@max_history_exchanges)
    |> Enum.flat_map(fn [question, answer] ->
      [
        %{role: "user", content: question},
        %{role: "assistant", content: answer}
      ]
    end)
  end

  @spec format_chunk(indexed_chunk()) :: String.t()
  def format_chunk({idx, {unit, _scores}}) do
    "[#{idx}] " <> Cake.Promptable.prompt_context(unit)
  end

  @spec system_message_with_context([String.t()]) :: String.t()
  def system_message_with_context(formatted_chunks) do
    context_block = Enum.join(formatted_chunks, "\n---\n")

    """
    You are a helpful assistant. Use the provided context to answer the user's question.
    Use inline citations like [1], [2] when drawing from a specific chunk. Each number corresponds to a numbered chunk below.
    If multiple chunks support a claim, cite all of them like [1][3].
    Prioritize citing specific page numbers when answering.
    If the answer cannot be found in the context, say so.
    Do NOT fabricate citations. Only cite chunks that actually support the claim.

    Context:
    #{context_block}
    """
  end

  @spec system_message_no_context() :: String.t()
  def system_message_no_context do
    """
    You are a helpful assistant. The user asked a question, but no relevant reference material was found in the available documents.
    Let the user know you could not find relevant information to answer their question.
    Do not guess or fabricate information.
    You may suggest that they rephrase their question or ask about a different topic covered by the available documents.
    """
  end

  # TODO: Query decomposition and expansion will go here.
  # TODO: Implement exponential memory decay per
  #   https://towardsdatascience.com/rag-isnt-enough-...
  # TODO: Future pass — summarize older history into a compressed preamble
  #   instead of truncating.
  # TODO: Per-tenant prompt templates.
  # TODO: Context assembly strategies (chunk ordering, interleaving, truncation
  #   by token count rather than chunk count).
end
