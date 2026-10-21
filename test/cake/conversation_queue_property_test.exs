defmodule Cake.ConversationQueuePropertyTest do
  @moduledoc """
  Property test for the `Cake.Conversation` autoask queue (#315): every
  `autoask/2` that arrives while a turn is `:generating` lands in
  `queued_question`, a later one overwrites an earlier one, and the queue
  is replayed as exactly one fresh turn when the current turn completes.

  The example in `conversation_test.exs` ("a second autoask during
  :generating is queued and runs after the first turn completes") pins
  one queued ask. The contract is about sequences, so this is a property
  over the list of questions asked during one blocked turn: however many
  arrive, and whatever they are, exactly one replay follows, its prompt
  ends with the last question, and the conversation is `:idle` with an
  empty queue afterwards.

  Synchronisation is deterministic throughout (`.claude/rules/test-conventions.md`):
  the first model call blocks on a message from the test, so every ask is
  cast while the turn is provably `:generating`; `:sys.get_state/1` is a
  call queued behind every cast from this process, so once it replies the
  conversation has handled them all; and the turn boundaries are observed
  through the `{:state_change, _}` and `{:response_ready, _}` broadcasts.
  The oracle is the count of model calls, two per iteration: the blocked
  turn and the replay.

  Like `conversation_self_ask_property_test.exs`, this drives the full
  GenServer with Mox collaborators and swaps the search backend via app
  env, so it runs synchronously.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Cake.Conversation
  alias Cake.Conversation.Events
  alias Cake.Search.Hit

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cake, :search_backend)
    Application.put_env(:cake, :search_backend, Cake.Search.Backend.Mock)
    on_exit(fn -> Application.put_env(:cake, :search_backend, original) end)
    :ok
  end

  # The question that opens the blocked turn. It is fixed, not generated:
  # the property is about the questions that arrive *during* that turn.
  @blocking_question "the question whose turn blocks"

  # How long the blocked model call waits for the test to release it before
  # giving up; the test releases it as soon as the queue is verified.
  @release_timeout 2_000

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # A non-empty sequence of questions to cast during the blocked turn.
  # Duplicates (including of the blocking question) are welcome: the
  # contract cares only about position, never content.
  defp questions do
    list_of(string(:printable, min_length: 1), min_length: 1, max_length: 8)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp conversation_opts(id) do
    %{
      id: id,
      embedder: "text-embedding-ada-002",
      response_model: "gpt-4o-mini",
      provider: :openai,
      gds: Cake.Support.FixtureGDS,
      embeddings: Cake.Embeddings.Mock,
      generation: Cake.Generation.Mock,
      responses: Cake.Responses.Mock
    }
  end

  # The blocked turn retrieves once; the replay reuses the cached results,
  # so one embed and one search per iteration, and one Responses pass per
  # turn. Counts are exact: a third turn would be an unexpected call.
  defp expect_retrieval_and_responses do
    expect(Cake.Embeddings.Mock, :embed, fn :openai, _params, _model ->
      {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
    end)

    expect(Cake.Search.Backend.Mock, :search, fn _query ->
      {:ok, [build_search_hit()]}
    end)

    expect(Cake.Responses.Mock, :process, 2, fn raw, _indexed, _opts ->
      %Cake.Responses.Result{
        raw_text: raw,
        final_text: raw,
        chunk_map: %{},
        citations: [],
        warnings: []
      }
    end)
  end

  # Every model call reports itself to the test with its ordinal, the task
  # pid and the prompt; the first one then blocks until released.
  defp stub_generation(test_pid, generation_calls) do
    stub(Cake.Generation.Mock, :complete, fn messages, _model, _opts ->
      call = :atomics.add_get(generation_calls, 1, 1)
      send(test_pid, {:generation_started, call, self(), messages})

      if call == 1 do
        receive do
          :release -> :ok
        after
          @release_timeout -> raise "the blocking turn was never released"
        end
      end

      {:ok, %{text: "answer #{call}", usage: %{}}}
    end)
  end

  defp start_subscribed(id) do
    {:ok, pid} = Conversation.start_link(conversation_opts(id))
    :ok = Phoenix.PubSub.subscribe(Cake.PubSub, Events.topic(id))

    allow(Cake.Embeddings.Mock, self(), pid)
    allow(Cake.Search.Backend.Mock, self(), pid)
    allow(Cake.Generation.Mock, self(), pid)
    allow(Cake.Responses.Mock, self(), pid)

    pid
  end

  defp stop_unsubscribed(pid, id) do
    :ok = Phoenix.PubSub.unsubscribe(Cake.PubSub, Events.topic(id))
    :ok = GenServer.stop(pid)
  end

  # ---------------------------------------------------------------------------
  # Property
  # ---------------------------------------------------------------------------

  property "asks during a :generating turn replay exactly once, with the last question" do
    check all(queued <- questions()) do
      last_question = List.last(queued)
      generation_calls = :atomics.new(1, [])

      expect_retrieval_and_responses()
      stub_generation(self(), generation_calls)

      id = "queue-prop-#{:erlang.unique_integer([:positive])}"
      pid = start_subscribed(id)

      # Open the turn and wait until it is blocked inside the model call,
      # so every ask below provably arrives while :generating.
      assert :ok = Conversation.autoask(pid, @blocking_question)
      assert_receive {:state_change, :generating}
      assert_receive {:generation_started, 1, blocked_task, _prompt}

      Enum.each(queued, fn question -> assert :ok = Conversation.autoask(pid, question) end)

      # A call behind every cast: once it replies, every ask was handled —
      # none crashed the conversation, and only the last one survived.
      assert %{state: :generating, queued_question: ^last_question} = :sys.get_state(pid)

      send(blocked_task, :release)

      # The blocked turn completes, then the queue replays as one fresh turn.
      assert_receive {:response_ready, _}
      assert_receive {:state_change, :idle}
      assert_receive {:state_change, :generating}
      assert_receive {:generation_started, 2, _replay_task, replay_prompt}
      assert List.last(replay_prompt) == %{role: "user", content: last_question}
      assert_receive {:response_ready, _}
      assert_receive {:state_change, :idle}

      # Nothing is left to replay, and nothing else was generated.
      assert %{state: :idle, queued_question: nil} = :sys.get_state(pid)
      assert :atomics.get(generation_calls, 1) == 2
      refute_received {:generation_started, _, _, _}
      refute_received {:state_change, _}
      refute_received {:response_ready, _}
      refute_received {:error, _}

      stop_unsubscribed(pid, id)
    end
  end
end
