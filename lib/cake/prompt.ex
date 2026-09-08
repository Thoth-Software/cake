defmodule Cake.Prompt do
  @moduledoc """
  Prompt-building and prompt-engineering for the conversation layer.

  Receives scored chunks from Search, filters by relevance floor and chunk
  ceiling, assigns dense 1..N indices, formats chunks into a numbered context
  block, integrates conversation history, and returns the messages list for
  the LLM.
  """

  use Boundary, top_level?: true, deps: [Cake, Cake.Search], exports: []

  alias Cake.Search.Result

  @type indexed_chunk :: {pos_integer(), Result.t()}
  @type context_quality :: :good | :none
  @type message :: %{role: String.t(), content: String.t()}

  @typedoc "A resolved sub-question and its intermediate answer, oldest first."
  @type answer_pair :: {String.t(), String.t()}

  @default_max_chunks 10
  @default_min_relevance 0.3
  @max_history_exchanges 5
  @default_max_context_tokens 4096
  @chars_per_token 4

  @spec prepare_context([Result.t()], keyword()) ::
          {[indexed_chunk()], context_quality()}
  def prepare_context(scored_results, opts \\ []) when is_list(scored_results) do
    max_chunks = Keyword.get(opts, :max_chunks, @default_max_chunks)
    min_relevance = Keyword.get(opts, :min_relevance, @default_min_relevance)

    indexed =
      scored_results
      |> Enum.filter(fn %Result{relevance_score: score} -> score >= min_relevance end)
      |> Enum.take(max_chunks)
      |> Enum.with_index(1)
      |> Enum.map(fn {result, idx} -> {idx, %{result | prompt_index: idx}} end)

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
  def format_chunk({idx, %Result{retrieval_unit: unit}}) do
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

  @doc """
  Build the messages list for a sequential-resolution step (#230).

  Like `build/4`, but folds the accumulated sub-question/answer pairs into
  the system message so each least-to-most step (and the final synthesis
  prompt) can condition on what was already answered. Pairs are budgeted by
  `fit_answer_pairs/2` against the `:max_context_tokens` opt (default
  #{@default_max_context_tokens}): the oldest pairs are evicted first, and
  with no surviving pairs the output is exactly `build/4`'s.
  """
  @spec build_with_prior_answers(
          [indexed_chunk()],
          String.t(),
          [answer_pair()],
          [String.t()],
          keyword()
        ) ::
          [message()]
  def build_with_prior_answers(indexed_chunks, question, prior_answers, history, opts \\ []) do
    budget = Keyword.get(opts, :max_context_tokens, @default_max_context_tokens)

    case fit_answer_pairs(prior_answers, budget) do
      [] ->
        build(indexed_chunks, question, history)

      kept ->
        [%{role: "system", content: system} | rest] = build(indexed_chunks, question, history)
        [%{role: "system", content: system <> "\n" <> answers_block(kept)} | rest]
    end
  end

  @doc """
  Keep the newest suffix of `answer_pairs` whose summed token cost (per
  `estimate_tokens/1`, question plus answer) fits within `budget` tokens,
  evicting the oldest pairs first.
  """
  @spec fit_answer_pairs([answer_pair()], non_neg_integer()) :: [answer_pair()]
  def fit_answer_pairs(answer_pairs, budget) when is_list(answer_pairs) do
    total = answer_pairs |> Enum.map(&pair_cost/1) |> Enum.sum()
    drop_oldest_until_fit(answer_pairs, total, budget)
  end

  defp drop_oldest_until_fit(pairs, total, budget) when total <= budget, do: pairs

  defp drop_oldest_until_fit([oldest | rest], total, budget) do
    drop_oldest_until_fit(rest, total - pair_cost(oldest), budget)
  end

  defp drop_oldest_until_fit([], _total, _budget), do: []

  defp pair_cost({question, answer}), do: estimate_tokens(question) + estimate_tokens(answer)

  defp answers_block(pairs) do
    rendered =
      Enum.map_join(pairs, "\n", fn {question, answer} -> "Q: #{question}\nA: #{answer}" end)

    "Previously answered sub-questions:\n#{rendered}"
  end

  @doc """
  Crude token estimate: ~#{@chars_per_token} characters per token, rounding
  up. Good enough for context budgeting; not a tokenizer.
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    div(String.length(text) + @chars_per_token - 1, @chars_per_token)
  end

  @doc """
  Build the messages list for the decomposition LLM call.

  The system prompt instructs the model to analyze the question and answer in
  JSON: `{"atomic": true}` when the question needs no decomposition, or
  `{"sub_questions": [...]}` when it does. `Cake.Decomposition.LLM` pairs this
  with the matching JSON schema and `c:Cake.Generation.complete_json/3`.
  """
  @spec decomposition_prompt(String.t()) :: [message()]
  def decomposition_prompt(question) when is_binary(question) do
    [
      %{role: "system", content: decomposition_system_message()},
      %{role: "user", content: question}
    ]
  end

  @spec decomposition_system_message() :: String.t()
  def decomposition_system_message do
    """
    You analyze a user's question and decide whether it should be decomposed into simpler sub-questions before searching reference documents.

    A question is atomic when it asks one thing about one subject and a single search serves it well. For an atomic question, respond with exactly this JSON:
    {"atomic": true}

    A question decomposes when answering it requires combining the answers to distinct, simpler questions — comparisons, multi-part questions, or questions with embedded prerequisites. For a decomposable question, respond with JSON matching this shape:
    {"sub_questions": ["<sub-question 1>", "<sub-question 2>"]}

    Each sub-question must be self-contained and independently searchable. Do not include any keys other than "atomic" or "sub_questions".
    Respond with JSON only — no prose, no code fences.
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

  # TODO: Query expansion will go here.
  # TODO: Implement exponential memory decay per
  #   https://towardsdatascience.com/rag-isnt-enough-...
  # TODO: Future pass — summarize older history into a compressed preamble
  #   instead of truncating.
  # TODO: Per-tenant prompt templates.
  # TODO: Context assembly strategies (chunk ordering, interleaving, truncation
  #   by token count rather than chunk count).
end
