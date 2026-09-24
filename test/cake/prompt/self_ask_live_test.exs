defmodule Cake.Prompt.SelfAskLiveTest do
  @moduledoc """
  The self-ask driver protocol against the production model (#247, item 13).

  `Cake.Conversation`'s self-ask loop rides plain `complete/3` plus marker
  parsing — `Cake.Prompt.parse_self_ask_response/1` looks for
  "Follow up:" and "So the final answer is:" — the loosest human-language
  contract in the codebase, and only a live call can show the model holds
  it. This suite drives the protocol directly through
  `Cake.Prompt.self_ask_prompt/3` and `Cake.Generation.OpenAI`, with no
  strategy module and no `Conversation`: a follow-up is answered by a
  plain completion, retrieval-free, and folded into the next driver prompt
  the way the loop folds a resolved pair. Full interleaved turns through
  `Conversation` belong to #271.

  Two invariants, never the content of a follow-up or an answer. Every
  driver reply carries one of the two markers: the parser is total — a
  marker-less reply is taken as the final answer verbatim — so
  parseability alone would pass a model that ignored the protocol
  entirely. And a trivially answerable question reaches the final-answer
  marker within the production iteration cap.
  """

  use Cake.LiveLLMCase

  alias Cake.Generation.OpenAI
  alias Cake.Prompt

  @follow_up_marker "Follow up:"
  @final_marker "So the final answer is:"
  @question "What is the sum of two and two?"
  @follow_up_answer_system "Answer the question in one short sentence."

  # The model Cake.Conversation drives the protocol with, from its config.
  defp model do
    fallback = Application.get_env(:cake, :default_response_model, "gpt-4o-mini")

    :cake
    |> Application.get_env(Cake.Conversation, [])
    |> Keyword.get(:response_model, fallback)
  end

  defp max_iterations, do: Application.get_env(:cake, :max_self_ask_iterations, 5)

  test "the markers this suite pins are the ones the driver prompt teaches" do
    system = Prompt.self_ask_system_message()

    assert system =~ @follow_up_marker
    assert system =~ @final_marker
  end

  test "every driver reply carries a marker, and a trivial question reaches the final answer within the cap" do
    {replies, outcome} = drive(@question, [], max_iterations(), [])

    assert replies != []

    for reply <- replies do
      assert reply =~ @follow_up_marker or reply =~ @final_marker,
             "driver reply carries neither protocol marker:\n#{reply}"
    end

    assert {:final, answer} = outcome
    assert String.trim(answer) != ""
  end

  # Mirrors Cake.Conversation.self_ask_round/5's accounting: at most `cap`
  # driver generations; each follow-up is resolved and folded into the next
  # prompt oldest-first (accumulated newest-first, reversed on use); the
  # cap spent with no final answer is {:exhausted, pairs}.
  defp drive(_question, pairs_rev, 0, replies_rev),
    do: {Enum.reverse(replies_rev), {:exhausted, Enum.reverse(pairs_rev)}}

  defp drive(question, pairs_rev, rounds_left, replies_rev) do
    messages = Prompt.self_ask_prompt(question, Enum.reverse(pairs_rev))
    assert {:ok, %{text: reply}} = OpenAI.complete(messages, model())

    case Prompt.parse_self_ask_response(reply) do
      {:final, answer} ->
        {Enum.reverse([reply | replies_rev]), {:final, answer}}

      {:follow_up, follow_up} ->
        pair = {follow_up, answer_follow_up(follow_up)}
        drive(question, [pair | pairs_rev], rounds_left - 1, [reply | replies_rev])
    end
  end

  # Stands in for the loop's retrieve-and-answer step: a plain completion
  # with no retrieved context.
  defp answer_follow_up(follow_up) do
    messages = [
      %{role: "system", content: @follow_up_answer_system},
      %{role: "user", content: follow_up}
    ]

    assert {:ok, %{text: answer}} = OpenAI.complete(messages, model())
    answer
  end
end
