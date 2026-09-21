defmodule Cake.ConversationIrcotPropertyTest do
  @moduledoc """
  Property test for the tier-5 IRCoT loop (#232): however the model
  paces its reasoning — completing after any number of retrieval rounds,
  or never — every retrieval result's provenance names a valid
  reasoning-step index (zero-based, strictly below the number of
  completed rounds), and the number of rounds never exceeds the
  `:max_ircot_iterations` cap.

  Unlike `conversation_property_test.exs` (pure functions, async), this
  drives the full GenServer pipeline with Mox stubs, so it runs
  synchronously with the search backend swapped via app env.
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

  # Fresh unit id per call so every retrieval round contributes a distinct
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

  property "every retrieval result's provenance names a valid reasoning-step index" do
    check all(cap <- integer(0..3), rounds_wanted <- integer(0..4), max_runs: 25) do
      question = "What is the warranty on the pump used in the RO-400?"
      searches = :counters.new(1, [])
      reasoning_calls = :counters.new(1, [])
      test_pid = self()

      stub(Cake.Decomposition.Mock, :decompose, fn ^question, _opts ->
        {:ok, %Cake.Decomposition.Result{original_question: question, strategy: :ircot}}
      end)

      stub(Cake.Embeddings.Mock, :embed, fn :openai, _params, _model ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      stub(Cake.Search.Backend.Mock, :search, fn _query ->
        :counters.add(searches, 1, 1)
        {:ok, [build_search_hit()]}
      end)

      # The driver keeps emitting retrieval queries for `rounds_wanted`
      # steps, then signals completion; when `rounds_wanted` exceeds the
      # cap, termination can only come from the cap.
      stub(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        step = :counters.get(reasoning_calls, 1)
        :counters.add(reasoning_calls, 1, 1)

        parsed =
          if step < rounds_wanted do
            %{"reasoning" => "reasoning step #{step}", "retrieval_query" => "query #{step}"}
          else
            %{"reasoning" => "The final reasoning.", "retrieval_query" => nil}
          end

        {:ok, %{parsed: parsed}}
      end)

      # Only the cap-exhaustion ending synthesizes with a plain completion.
      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "synthesized answer", usage: %{}}}
      end)

      stub(Cake.Responses.Mock, :process, fn raw, indexed, _opts ->
        send(test_pid, {:processed, indexed})

        %Cake.Responses.Result{
          raw_text: raw,
          final_text: raw,
          chunk_map: %{},
          citations: [],
          warnings: []
        }
      end)

      id = "ircot-prop-#{:erlang.unique_integer([:positive])}"
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
        max_ircot_iterations: cap
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
      assert_receive {:processed, indexed}

      rounds = :counters.get(searches, 1)
      assert rounds == min(rounds_wanted, cap)

      # Dense, zero-based step indices: one per completed retrieval round,
      # nothing outside 0..rounds-1.
      indexes =
        indexed
        |> Enum.map(fn {_idx, result} -> result.provenance.sub_question_index end)
        |> Enum.sort()

      assert indexes == Enum.to_list(0..(rounds - 1)//1)

      Enum.each(indexed, fn {_idx, result} ->
        assert result.provenance.decomposed == true
        assert result.provenance.original_query == question
      end)

      :ok = Phoenix.PubSub.unsubscribe(Cake.PubSub, topic)
      :ok = GenServer.stop(pid)
    end
  end
end
