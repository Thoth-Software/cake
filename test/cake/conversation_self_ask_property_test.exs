defmodule Cake.ConversationSelfAskPropertyTest do
  @moduledoc """
  Property test for the tier-4 self-ask interleaving loop (#231): however
  eagerly the model keeps asking follow-ups, the number of follow-up
  rounds — and with it the number of follow-up searches — never exceeds
  the `:max_self_ask_iterations` cap.

  Unlike `conversation_property_test.exs` (pure functions, async), this
  drives the full GenServer pipeline with always-follow-up Mox stubs, so
  it runs synchronously with the search backend swapped via app env.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Cake.Conversation
  alias Cake.Search.Hit

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cake, :search_backend)
    Application.put_env(:cake, :search_backend, Cake.Search.Backend.Mock)
    on_exit(fn -> Application.put_env(:cake, :search_backend, original) end)
    :ok
  end

  # Fresh unit id per call so every follow-up round contributes a distinct
  # retrieval unit to the merged context.
  defp build_search_hit do
    id = "c-#{:erlang.unique_integer([:positive])}"

    %Hit{
      id: id,
      score: 1.0,
      source: %{
        "id" => id,
        "body" => "chunk body",
        "embedding" => [0.1, 0.2, 0.3],
        "metadata" => %{id: id, label: "L", preview: "p", source_ref: nil, extras: %{}}
      }
    }
  end

  property "follow-up rounds never exceed the :max_self_ask_iterations cap" do
    check all(cap <- integer(0..3), max_runs: 25) do
      question = "What is the warranty on the pump used in the RO-400?"
      searches = :counters.new(1, [])

      stub(Cake.Decomposition.Mock, :decompose, fn ^question, _opts ->
        {:ok, %Cake.Decomposition.Result{original_question: question, strategy: :self_ask}}
      end)

      stub(Cake.Embeddings.Mock, :embed, fn :openai, _params, _model ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      stub(Cake.Search.Backend.Mock, :search, fn _query ->
        :counters.add(searches, 1, 1)
        {:ok, [build_search_hit()]}
      end)

      # The driver prompt (the only prompt teaching the final-answer
      # marker) always asks another follow-up; every other prompt gets a
      # marker-free answer. Termination can only come from the cap.
      stub(Cake.Generation.Mock, :complete, fn messages, _model, _opts ->
        [%{content: system} | _] = messages

        text =
          if String.contains?(system, "So the final answer is:") do
            "Follow up: Which pump does the RO-400 use?"
          else
            "An answer without a final marker."
          end

        {:ok, %{text: text, usage: %{}}}
      end)

      stub(Cake.Responses.Mock, :process, fn raw, _indexed, _opts ->
        %Cake.Responses.Result{
          raw_text: raw,
          final_text: raw,
          chunk_map: %{},
          citations: [],
          warnings: []
        }
      end)

      id = "self-ask-prop-#{:erlang.unique_integer([:positive])}"
      topic = Cake.Conversation.Events.topic(id)

      opts = %{
        id: id,
        embedder: "text-embedding-ada-002",
        response_model: "gpt-4o-mini",
        provider: :openai,
        gds: Cake.Support.FixtureGDS,
        embeddings: Cake.Embeddings.Mock,
        generation: Cake.Generation.Mock,
        responses: Cake.Responses.Mock,
        decomposition: Cake.Decomposition.Mock,
        max_self_ask_iterations: cap
      }

      {:ok, pid} = Conversation.start_link(opts)
      :ok = Phoenix.PubSub.subscribe(Cake.PubSub, topic)

      allow(Cake.Decomposition.Mock, self(), pid)
      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Backend.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      assert :ok = Conversation.autoask(pid, question)
      assert_receive {:response_ready, _}

      assert :counters.get(searches, 1) == cap

      :ok = Phoenix.PubSub.unsubscribe(Cake.PubSub, topic)
      :ok = GenServer.stop(pid)
    end
  end
end
