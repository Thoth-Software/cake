# User-owned LawSpec adapter for laws/prompt_context.lawspec.
defmodule Cake.Laws.PromptContext do
  @moduledoc """
  Adapts `Cake.Prompt`'s context assembly to the `cake.laws.prompt_context`
  unit: `prepare_context/2`, `format_chunk/1`, `history_messages/1`,
  `build/4` and the two system messages.

  Each generated result becomes what `Cake.Search` hands `Cake.Prompt`: a
  `Cake.Search.Result` whose retrieval unit is a `Cake.Laws.FakeUnit` carrying
  the result's prompt context. Its relevance score is the generated
  hundredths divided by 100, and `nil` when the result has none; a floor is
  divided the same way, so a score and a floor from the same hundredth are
  the same float.

  The translation is strict on purpose, so a shape the specification does
  not name fails the law instead of passing through. A result that comes
  back from Cake must be the result that went in, with only its
  `prompt_index` changed; a context quality other than `:good` or `:none`, a
  role other than the three, or a message with a key besides `:role` and
  `:content` has no clause here.
  """

  alias Cake.Laws.FakeUnit
  alias Cake.Prompt
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias LawSpec.Data.Message
  alias LawSpec.Data.PreparedContext
  alias LawSpec.Data.PromptChunk
  alias LawSpec.Data.ScoredResult

  @doc """
  `Prompt.prepare_context/2` of `results`, with `max_chunks` and with
  `min_relevance` as `floor` hundredths.
  """
  @spec prepare_context(non_neg_integer(), integer(), [LawSpec.Data.scored_result()]) ::
          LawSpec.Data.prepared_context()
  def prepare_context(max_chunks, floor, results)
      when is_integer(max_chunks) and is_integer(floor) and is_list(results) do
    results
    |> Enum.map(&to_result/1)
    |> Prompt.prepare_context(max_chunks: max_chunks, min_relevance: floor / 100)
    |> to_prepared_context()
  end

  @doc "`Prompt.prepare_context/2` of `results`, with no options."
  @spec prepare_context_by_default([LawSpec.Data.scored_result()]) ::
          LawSpec.Data.prepared_context()
  def prepare_context_by_default(results) when is_list(results) do
    results
    |> Enum.map(&to_result/1)
    |> Prompt.prepare_context()
    |> to_prepared_context()
  end

  @doc "`Prompt.format_chunk/1` of `{index, result}`."
  @spec format_chunk(non_neg_integer(), LawSpec.Data.scored_result()) :: binary()
  def format_chunk(index, result) when is_integer(index) do
    Prompt.format_chunk({index, to_result(result)})
  end

  @doc "`Prompt.history_messages/1` of `history`, as message records."
  @spec history_messages([binary()]) :: [LawSpec.Data.message()]
  def history_messages(history) when is_list(history) do
    history
    |> Prompt.history_messages()
    |> Enum.map(&to_message/1)
  end

  @doc "`Prompt.build/4` of `chunks`, `question` and `history`, with no options."
  @spec build([LawSpec.Data.prompt_chunk()], binary(), [binary()]) :: [LawSpec.Data.message()]
  def build(chunks, question, history)
      when is_list(chunks) and is_binary(question) and is_list(history) do
    chunks
    |> Enum.map(&to_indexed_chunk/1)
    |> Prompt.build(question, history)
    |> Enum.map(&to_message/1)
  end

  @doc "`Prompt.system_message_with_context/1` of `formatted_chunks`."
  @spec system_message_with_context([binary()]) :: binary()
  def system_message_with_context(formatted_chunks) when is_list(formatted_chunks) do
    Prompt.system_message_with_context(formatted_chunks)
  end

  @doc """
  `Prompt.system_message_no_context/0`. The argument is LawSpec's unit value:
  a LawSpec function needs an input, and the Cake function takes none.
  """
  @spec system_message_no_context(:ok) :: binary()
  def system_message_no_context(:ok), do: Prompt.system_message_no_context()

  defp to_result(%ScoredResult{context: context, score: score}) do
    %Result{
      retrieval_unit: %FakeUnit{
        metadata: %{id: "laws", label: "Laws", preview: "", source_ref: nil, extras: %{}},
        prompt_context: context
      },
      relevance_score: from_hundredths(score),
      hit_source: :search,
      index: "laws",
      provenance: %Provenance{search_type: :hybrid, query_text: "laws"}
    }
  end

  # Cake may give a result a prompt index and must leave the rest of it alone,
  # so the result read back has to rebuild into the result Cake returned.
  defp to_scored_result(%Result{} = result) do
    %Result{retrieval_unit: %FakeUnit{prompt_context: context}, relevance_score: score} = result
    scored = %ScoredResult{context: context, score: to_hundredths(score)}
    ^result = %{to_result(scored) | prompt_index: result.prompt_index}
    scored
  end

  defp to_prepared_context({indexed_chunks, quality}) when is_list(indexed_chunks) do
    %PreparedContext{
      chunks: Enum.map(indexed_chunks, &to_prompt_chunk/1),
      quality: to_quality(quality)
    }
  end

  defp to_prompt_chunk({index, %Result{prompt_index: prompt_index} = result})
       when is_integer(index) do
    %PromptChunk{
      index: index,
      prompt_index: to_maybe(prompt_index),
      result: to_scored_result(result)
    }
  end

  defp to_indexed_chunk(%PromptChunk{index: index, prompt_index: prompt_index, result: result}) do
    {index, %{to_result(result) | prompt_index: from_maybe(prompt_index)}}
  end

  defp to_quality(:good), do: %LawSpec.Data.ContextQualityGood{}
  defp to_quality(:none), do: %LawSpec.Data.ContextQualityNone{}

  defp to_message(%{role: role, content: content} = message)
       when map_size(message) == 2 and is_binary(content) do
    %Message{role: to_role(role), content: content}
  end

  defp to_role("system"), do: %LawSpec.Data.RoleSystem{}
  defp to_role("user"), do: %LawSpec.Data.RoleUser{}
  defp to_role("assistant"), do: %LawSpec.Data.RoleAssistant{}

  defp from_hundredths(:absent), do: nil
  defp from_hundredths({:present, hundredths}) when is_integer(hundredths), do: hundredths / 100

  defp to_hundredths(nil), do: :absent
  defp to_hundredths(score) when is_float(score), do: {:present, round(score * 100)}

  defp from_maybe(:absent), do: nil
  defp from_maybe({:present, value}), do: value

  defp to_maybe(nil), do: :absent
  defp to_maybe(value), do: {:present, value}
end
