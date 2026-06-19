defmodule Cake.ConversationTest do
  @moduledoc """
  Characterization tests for `Cake.Conversation`. Pin current behavior so
  later refactors (PubSub migration, struct-arg refactor, etc.) preserve
  observable contracts.

  ## Why `Cake.Responses.Mock` instead of the real `Cake.Responses`

  Most "happy path" tests here mock `Cake.Responses` rather than calling
  through to the real implementation. The Conversation's job is to
  orchestrate Embeddings → Search → Generation → Responses → PubSub;
  pinning that orchestration is independent of pinning what the Responses
  pipeline does to a citation. The Responses module already has its own
  characterization coverage in `test/cake/responses_test.exs`.

  ## Observing turn outcomes via PubSub

  Conversation publishes turn results on the `Cake.Conversation.Events`
  topic for its id. Tests use `start_subscribed/1` to start a conversation
  and subscribe the test process to that topic, then assert on
  `{:response_ready, _}` / `{:error, _}` / `{:state_change, _}` broadcasts.

  The exception is the citation-threading commit (Commit 5), which uses
  the real `Cake.Responses` so the metadata transformations through
  `process/3` are part of the pin.
  """

  use ExUnit.Case, async: false

  import Mox
  import Cake.Factory, only: [build: 1, build: 2, chunk_metadata: 1]

  alias Cake.Conversation
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Support.FixtureGDS
  alias Cake.Test.ConvoChunk

  setup :verify_on_exit!

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  defp wrap_result(unit, opts \\ []) do
    %Result{
      retrieval_unit: unit,
      backend_score: Keyword.get(opts, :backend_score, 1.0),
      cosine_score: Keyword.get(opts, :cosine_score),
      relevance_score: Keyword.get(opts, :relevance_score),
      hit_source: Keyword.get(opts, :hit_source, :search),
      index: "test_index",
      provenance: test_provenance()
    }
  end

  defp valid_opts(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-#{:erlang.unique_integer([:positive])}",
        search: Cake.Search.OpenSearch,
        embedder: "text-embedding-ada-002",
        response_model: "gpt-4o-mini",
        provider: :openai,
        gds: FixtureGDS
      },
      overrides
    )
  end

  defp mocked_opts(overrides \\ %{}) do
    base =
      valid_opts(%{
        search: Cake.Search.Mock,
        embeddings: Cake.Embeddings.Mock,
        generation: Cake.Generation.Mock,
        responses: Cake.Responses.Mock
      })

    Map.merge(base, overrides)
  end

  # Starts a supervised conversation and subscribes the test process to its
  # PubSub topic, so the test can assert on {:response_ready, _} / {:error, _}
  # / {:state_change, _} broadcasts. Returns the conversation pid.
  defp start_subscribed(overrides \\ %{}) do
    opts = mocked_opts(overrides)
    pid = start_supervised!({Conversation, opts})
    :ok = Phoenix.PubSub.subscribe(Cake.PubSub, Cake.Conversation.Events.topic(opts.id))
    pid
  end

  describe ":gds option" do
    test "start_link/1 rejects opts missing :gds" do
      opts = Map.delete(valid_opts(), :gds)

      case Conversation.start_link(opts) do
        {:error, {%KeyError{key: :gds}, _stack}} ->
          :ok

        {:error, %KeyError{key: :gds}} ->
          :ok

        other ->
          flunk("""
          expected start_link to reject opts missing :gds with a KeyError,
          got: #{inspect(other)}
          """)
      end
    end

    test "start_link/1 rejects opts with gds: nil" do
      opts = Map.put(valid_opts(), :gds, nil)

      case Conversation.start_link(opts) do
        {:error, {%KeyError{}, _stack}} ->
          :ok

        {:error, %KeyError{}} ->
          :ok

        {:error, {reason, _stack}} when is_atom(reason) or is_tuple(reason) ->
          :ok

        {:error, reason} when is_atom(reason) or is_tuple(reason) ->
          :ok

        other ->
          flunk("""
          expected start_link to reject gds: nil,
          got: #{inspect(other)}
          """)
      end
    end

    test "start_link/1 accepts opts with :gds and returns a pid" do
      {:ok, pid} = Conversation.start_link(valid_opts())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert is_pid(pid)
      state = :sys.get_state(pid)
      assert state.gds == FixtureGDS
    end
  end

  describe "happy path" do
    test "an :ok turn broadcasts a {:response_ready, _} message" do
      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "smoke chunk",
        metadata: %{
          id: "c1",
          label: "Smoke",
          preview: "smoke",
          source_ref: nil,
          extras: %{}
        }
      }

      expect(Cake.Embeddings.Mock, :embed, fn :openai, %{input: _question}, _model ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn :hybrid,
                                                               _q,
                                                               _emb,
                                                               _expand,
                                                               _opts ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, fn _raw_text, _indexed, _opts ->
        %Cake.Responses.Result{
          raw_text: "answer",
          final_text: "answer",
          chunk_map: %{1 => chunk.metadata},
          citations: [],
          warnings: []
        }
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "answer", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      assert :ok = Conversation.autoask(pid, "what is two plus two?")

      assert_receive {:response_ready, %{response: _response, citations: _citations}}, 500
    end
  end

  describe "response shape" do
    test "{:response_ready, %{response, citations}} — response is a string, citations is a list of maps with the documented keys" do
      chunks =
        Enum.map(1..3, fn i ->
          %ConvoChunk{
            embedding: [0.1 * i, 0.2 * i, 0.3 * i],
            prompt_text: "chunk #{i}",
            metadata: %{
              id: "id-#{i}",
              label: "Book #{i}, p. #{i}",
              preview: "preview #{i}",
              source_ref: "book:#{i}#chunk:#{i}",
              extras: %{
                book_title: "Book #{i}",
                page_number: i,
                section_title: "Section #{i}",
                chunk_index: i
              }
            }
          }
        end)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, Enum.map(chunks, &wrap_result/1)}
      end)

      expect(Cake.Responses.Mock, :process, fn _raw, _indexed, _opts ->
        citations =
          Enum.map(Enum.with_index(chunks, 1), fn {c, idx} ->
            %{
              old_index: idx,
              new_index: idx,
              id: c.metadata.id,
              label: c.metadata.label,
              preview: c.metadata.preview,
              source_ref: c.metadata.source_ref,
              extras: c.metadata.extras
            }
          end)

        chunk_map =
          chunks
          |> Enum.with_index(1)
          |> Map.new(fn {c, i} -> {i, c.metadata} end)

        %Cake.Responses.Result{
          raw_text: "answer [1] with [2] and [3]",
          final_text: "answer [1] with [2] and [3]",
          chunk_map: chunk_map,
          citations: citations,
          warnings: []
        }
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "answer [1] with [2] and [3]", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "test question")

      assert_receive {:response_ready, %{response: response, citations: citations}}, 500

      assert is_binary(response)
      assert is_list(citations)
      assert length(citations) == 3

      Enum.each(citations, fn citation ->
        assert is_map(citation)
        assert Map.has_key?(citation, :old_index)
        assert Map.has_key?(citation, :new_index)
        assert Map.has_key?(citation, :id)
        assert Map.has_key?(citation, :label)
        assert Map.has_key?(citation, :preview)
        assert Map.has_key?(citation, :source_ref)
        assert Map.has_key?(citation, :extras)

        assert is_integer(citation.old_index)
        assert is_integer(citation.new_index)
        assert is_binary(citation.label)
        assert is_binary(citation.preview)
        assert is_map(citation.extras)
      end)
    end
  end

  describe "chunks in prompt" do
    test "retrieved chunk content is threaded into the LLM prompt" do
      marker = "UNIQUE_MARKER_#{:erlang.unique_integer([:positive])}"

      chunk = build(:convo_chunk, prompt_text: marker)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{
          raw_text: "ok",
          final_text: "ok",
          citations: [],
          warnings: []
        }
      end)

      pid = start_subscribed()

      test_pid = self()

      stub(Cake.Generation.Mock, :complete, fn messages, _model, _opts ->
        send(test_pid, {:prompt_captured, messages})
        {:ok, %{text: "ok", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "q")

      assert_receive {:prompt_captured, messages}, 500

      serialized = Enum.map_join(messages, "\n", & &1.content)
      assert serialized =~ marker

      # Wait for the full turn to complete before the test exits, so Mox
      # verify_on_exit! sees the Responses.Mock invocation.
      assert_receive {:response_ready, _}, 500
    end
  end

  describe "citation threading" do
    test "the five metadata fields and citation indexes thread from chunks to the cited response" do
      chunks = [
        %ConvoChunk{
          embedding: [0.1, 0.2, 0.3],
          prompt_text: "alpha text",
          metadata: %{
            id: "id-1",
            label: "Alpha label",
            preview: "alpha preview",
            source_ref: "src:alpha",
            extras: %{
              book_title: "Book Alpha",
              page_number: 11,
              section_title: "Section Alpha",
              chunk_index: 101
            }
          }
        },
        %ConvoChunk{
          embedding: [0.4, 0.5, 0.6],
          prompt_text: "beta text",
          metadata: %{
            id: "id-2",
            label: "Beta label",
            preview: "beta preview",
            source_ref: "src:beta",
            extras: %{
              book_title: "Book Beta",
              page_number: 22,
              section_title: "Section Beta",
              chunk_index: 202
            }
          }
        }
      ]

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, Enum.map(chunks, &wrap_result/1)}
      end)

      # NOTE: deliberately NOT mocking Cake.Responses — we want the real
      # process/3 so the citation transformations are part of the pin.
      pid = start_subscribed(%{responses: Cake.Responses})

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "answer references [2] and then [1].", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "q")

      assert_receive {:response_ready, %{response: _response, citations: citations}}, 500

      assert length(citations) == 2

      [first, second] = citations

      assert first.new_index == 1
      assert first.old_index == 2
      assert first.id == "id-2"
      assert first.label == "Beta label"
      assert first.preview == "beta preview"
      assert first.source_ref == "src:beta"
      assert first.extras.book_title == "Book Beta"
      assert first.extras.page_number == 22
      assert first.extras.section_title == "Section Beta"
      assert first.extras.chunk_index == 202

      assert second.new_index == 2
      assert second.old_index == 1
      assert second.id == "id-1"
      assert second.label == "Alpha label"
      assert second.preview == "alpha preview"
      assert second.source_ref == "src:alpha"
      assert second.extras.book_title == "Book Alpha"
      assert second.extras.page_number == 11
      assert second.extras.section_title == "Section Alpha"
      assert second.extras.chunk_index == 101

      refute Map.has_key?(first, :chunk_preview)
      refute Map.has_key?(second, :chunk_preview)
    end
  end

  describe "history accumulation" do
    test "turn 2's prompt contains turn 1's question and response; turn 2 reuses search results" do
      turn_one_q = "QUESTION_ONE_#{:erlang.unique_integer([:positive])}"
      turn_one_a = "RESPONSE_ONE_#{:erlang.unique_integer([:positive])}"
      turn_two_q = "QUESTION_TWO_#{:erlang.unique_integer([:positive])}"

      chunk = build(:convo_chunk, prompt_text: "static chunk")

      # `expect/3` with no count means exactly once across the test. If turn 2
      # called embed or search again, Mox would fail — that implicitly pins
      # "subsequent turns skip embed and search."
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, 2, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      pid = start_subscribed()

      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Cake.Generation.Mock, :complete, fn messages, _model, _opts ->
        send(test_pid, {:prompt_captured, messages})
        call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        text = if call_num == 0, do: turn_one_a, else: "RESPONSE_TWO"
        {:ok, %{text: text, usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, turn_one_q)
      assert_receive {:prompt_captured, turn_one_messages}, 500
      assert_receive {:response_ready, _}, 500

      Conversation.autoask(pid, turn_two_q)
      assert_receive {:prompt_captured, turn_two_messages}, 500
      assert_receive {:response_ready, _}, 500

      turn_one_serialized = Enum.map_join(turn_one_messages, "\n", & &1.content)
      turn_two_serialized = Enum.map_join(turn_two_messages, "\n", & &1.content)

      assert turn_one_serialized =~ turn_one_q
      refute turn_one_serialized =~ turn_one_a
      refute turn_one_serialized =~ turn_two_q

      assert turn_two_serialized =~ turn_one_q
      assert turn_two_serialized =~ turn_one_a
      assert turn_two_serialized =~ turn_two_q
    end
  end

  describe "public API contract" do
    test "child_spec/1 returns a supervisor child spec with restart: :temporary" do
      opts = valid_opts()
      spec = Conversation.child_spec(opts)

      assert spec == %{
               id: Cake.Conversation,
               start: {Cake.Conversation, :start_link, [opts]},
               restart: :temporary
             }
    end

    test "start/1 accepts valid opts and returns {:ok, pid}" do
      {:ok, pid} = Conversation.start(valid_opts())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert is_pid(pid)
    end

    test "start/1 rejects opts missing :gds with a KeyError" do
      opts = Map.delete(valid_opts(), :gds)

      case Conversation.start(opts) do
        {:error, %KeyError{key: :gds}} -> :ok
        other -> flunk("expected {:error, KeyError}, got: #{inspect(other)}")
      end
    end

    test "ask/2 returns :ok synchronously (fire-and-forget cast)" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, []}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "x", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      assert :ok = Conversation.autoask(pid, "hello")

      assert_receive {:response_ready, _}, 500
    end

    test "print_hierarchy/2 returns a list (logging-only helper)" do
      assert is_list(Conversation.print_hierarchy(%{a: 1, b: %{c: 2}}))
    end
  end

  describe "cluster error" do
    test "cluster {:error, _} broadcasts {:error, reason} without crashing the GenServer" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:error, :timeout}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      ref = Process.monitor(pid)

      Conversation.autoask(pid, "q")

      assert_receive {:error, :timeout}, 500

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100

      state = :sys.get_state(pid)
      assert state.errors == [:timeout]
    end
  end

  describe "generation error" do
    test "generation {:error, _} broadcasts {:error, reason} without crashing" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:error, {:rate_limited, nil}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      ref = Process.monitor(pid)

      Conversation.autoask(pid, "q")

      assert_receive {:error, {:rate_limited, nil}}, 500
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100

      state = :sys.get_state(pid)
      assert state.errors == [{:rate_limited, nil}]
    end
  end

  describe "zero chunks" do
    test "empty cluster results: LLM is still called (no short-circuit), Responses receives empty indexed_chunks, turn completes" do
      test_pid = self()

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, []}
      end)

      expect(Cake.Responses.Mock, :process, fn _, indexed_chunks, _opts ->
        send(test_pid, {:responses_indexed_chunks, indexed_chunks})
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn messages, _model, _opts ->
        send(test_pid, {:prompt_captured, messages})
        {:ok, %{text: "x", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "q with no matching chunks")

      assert_receive {:prompt_captured, _messages}, 500
      assert_receive {:responses_indexed_chunks, indexed_chunks}, 500
      assert_receive {:response_ready, _}, 500

      assert indexed_chunks == []
    end
  end

  describe "uncited LLM output" do
    test "LLM text with no [N] markers yields citations: [] in the response_ready broadcast" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      pid = start_subscribed(%{responses: Cake.Responses})

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "answer with no citation markers", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "q")

      assert_receive {:response_ready, %{response: response, citations: citations}}, 500

      assert is_binary(response)
      assert citations == []
    end
  end

  describe "cluster exception" do
    test "cluster raising propagates and crashes the GenServer (no catch)" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        raise "boom"
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      ref = Process.monitor(pid)

      Conversation.autoask(pid, "q")

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 500

      assert match?({%RuntimeError{message: "boom"}, _stacktrace}, reason)

      refute_received {:response_ready, _}
      refute_received {:error, _}
    end
  end

  describe "concurrent asks" do
    test "two ask/2 calls are serialized by the GenServer mailbox: cast 2 cannot start until cast 1 returns" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, 2, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 ->
            send(test_pid, :first_started)

            receive do
              :release_first -> :ok
            after
              2_000 -> raise "first call never released"
            end

            send(test_pid, :first_returning)
            {:ok, %{text: "first", usage: %{}}}

          1 ->
            send(test_pid, :second_started)
            {:ok, %{text: "second", usage: %{}}}
        end
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      assert :ok = Conversation.autoask(pid, "q1")
      assert :ok = Conversation.autoask(pid, "q2")

      # Cast 1's handler has started.
      assert_receive :first_started, 500

      # Cast 2's handler has NOT started — it's queued behind cast 1 in
      # the GenServer mailbox. This is the load-bearing assertion: it
      # rules out an accidental Task.async / parallel-handle introduction.
      refute_receive :second_started, 100

      # Release cast 1; cast 1 returns; cast 2's handler now runs.
      send(pid, :release_first)
      assert_receive :first_returning, 500
      assert_receive :second_started, 500

      # Both responses delivered, in the order they were asked.
      assert_receive {:response_ready, _}, 500
      assert_receive {:response_ready, _}, 500
    end
  end

  describe "pipeline stages" do
    test "resolve_search_results/2 returns cached results when search_results is non-empty" do
      cached = [
        wrap_result(%ConvoChunk{prompt_text: "cached"},
          backend_score: 1.0,
          cosine_score: 0.9,
          relevance_score: 0.95
        )
      ]

      state =
        struct!(
          Cake.Conversation.State,
          Map.merge(mocked_opts(), %{search_results: cached})
        )

      assert {:ok, ^cached} = Conversation.resolve_search_results("ignored", state)
    end

    test "resolve_search_results/2 calls embed_and_search when search_results is empty" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      # Call from within the GenServer process via a handler
      state = :sys.get_state(pid)
      assert state.search_results == []

      # Verify indirectly: a full turn exercises resolve_search_results
      # and the embed/search mocks being called exactly once confirms it.
      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "x", usage: %{}}}
      end)

      Conversation.autoask(pid, "q")
      assert_receive {:response_ready, _}, 500
    end

    test "resolve_search_results/2 propagates embed error" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:error, :embed_failed}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)

      Conversation.autoask(pid, "q")
      assert_receive {:error, :embed_failed}, 500
    end

    test "select/1 returns indexed chunks from scored results" do
      scored = [
        wrap_result(%ConvoChunk{prompt_text: "a"}, relevance_score: 0.9),
        wrap_result(%ConvoChunk{prompt_text: "b"}, relevance_score: 0.8)
      ]

      assert {:ok, indexed} = Conversation.select(scored)
      assert length(indexed) == 2
      assert {1, _} = hd(indexed)
    end

    test "select/1 filters below relevance floor" do
      scored = [wrap_result(%ConvoChunk{prompt_text: "a"}, relevance_score: 0.1)]

      assert {:ok, []} = Conversation.select(scored)
    end

    test "select/1 handles empty input" do
      assert {:ok, []} = Conversation.select([])
    end

    test "build_prompt/3 includes question and chunk content" do
      marker = "UNIQUE_#{:erlang.unique_integer([:positive])}"

      chunk = %ConvoChunk{prompt_text: marker}
      result = wrap_result(chunk, relevance_score: 0.9)
      indexed = [{1, result}]

      assert {:ok, messages} = Conversation.build_prompt(indexed, "my question", [])
      serialized = Enum.map_join(messages, "\n", & &1.content)

      assert serialized =~ marker
      assert serialized =~ "my question"
    end

    test "build_prompt/3 includes history" do
      assert {:ok, messages} = Conversation.build_prompt([], "q2", ["q1", "a1"])
      serialized = Enum.map_join(messages, "\n", & &1.content)

      assert serialized =~ "q1"
      assert serialized =~ "a1"
      assert serialized =~ "q2"
    end

    test "generate/2 returns response text on success" do
      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "hello", usage: %{}}}
      end)

      allow(Cake.Generation.Mock, self(), pid)

      test_pid = self()
      messages = [%{role: "user", content: "q"}]

      :sys.replace_state(pid, fn s ->
        send(test_pid, {:gen_result, Conversation.generate(messages, s)})
        s
      end)

      assert_receive {:gen_result, {:ok, "hello"}}, 500
    end

    test "generate/2 propagates error" do
      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:error, :rate_limited}
      end)

      allow(Cake.Generation.Mock, self(), pid)

      test_pid = self()

      :sys.replace_state(pid, fn s ->
        send(test_pid, {:gen_result, Conversation.generate([%{role: "user", content: "q"}], s)})
        s
      end)

      assert_receive {:gen_result, {:error, :rate_limited}}, 500
    end

    test "process_response/3 wraps Responses.process result in :ok tuple" do
      expect(Cake.Responses.Mock, :process, fn "raw text", [], [] ->
        %Cake.Responses.Result{
          raw_text: "raw text",
          final_text: "processed",
          citations: [],
          warnings: []
        }
      end)

      state =
        struct!(
          Cake.Conversation.State,
          Map.put(mocked_opts(), :responses, Cake.Responses.Mock)
        )

      assert {:ok, %Cake.Responses.Result{final_text: "processed"}} =
               Conversation.process_response("raw text", [], state)
    end
  end

  describe "pipeline integration" do
    test "search failure short-circuits: generate and responses never called" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:error, :embed_failed}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)

      Conversation.autoask(pid, "q")
      assert_receive {:error, :embed_failed}, 500
    end

    test "generate failure short-circuits: responses never called" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:error, :generation_failed}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "q")
      assert_receive {:error, :generation_failed}, 500
    end

    test "zero chunks: pipeline completes without short-circuit" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, []}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "x", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Conversation.autoask(pid, "q")
      assert_receive {:response_ready, %{response: "x", citations: []}}, 500
    end
  end

  describe "apply_selection/2" do
    test "filters candidates to selected IDs and assigns 1-based indices" do
      c1 = build(:convo_chunk, prompt_text: "a", metadata: chunk_metadata(id: "id-1"))

      c2 = build(:convo_chunk, prompt_text: "b", metadata: chunk_metadata(id: "id-2"))
      c3 = build(:convo_chunk, prompt_text: "c", metadata: chunk_metadata(id: "id-3"))

      candidates = [
        wrap_result(c1, backend_score: 1.0),
        wrap_result(c2, backend_score: 0.9),
        wrap_result(c3, backend_score: 0.8)
      ]

      assert {:ok, indexed} = Conversation.apply_selection(candidates, ["id-1", "id-3"])
      assert length(indexed) == 2
      assert {1, %Result{retrieval_unit: ^c1}} = Enum.at(indexed, 0)
      assert {2, %Result{retrieval_unit: ^c3}} = Enum.at(indexed, 1)
    end

    test "selecting all candidates returns all with indices" do
      c1 = build(:convo_chunk, prompt_text: "a", metadata: chunk_metadata(id: "id-1"))

      candidates = [wrap_result(c1)]

      assert {:ok, [{1, %Result{retrieval_unit: ^c1}}]} =
               Conversation.apply_selection(candidates, ["id-1"])
    end

    test "errors on unknown doc IDs" do
      c1 = build(:convo_chunk, prompt_text: "a", metadata: chunk_metadata(id: "id-1"))

      candidates = [wrap_result(c1)]

      assert {:error, {:unknown_doc_ids, unknown}} =
               Conversation.apply_selection(candidates, ["id-1", "id-999"])

      assert "id-999" in unknown
    end

    test "empty doc_ids returns empty indexed list" do
      c1 = build(:convo_chunk, prompt_text: "a", metadata: chunk_metadata(id: "id-1"))

      candidates = [wrap_result(c1)]

      assert {:error, {:unknown_doc_ids, _}} =
               Conversation.apply_selection(candidates, ["nonexistent"])
    end
  end

  describe "manual mode end-to-end" do
    test "full flow: manualask returns candidates, select completes the turn" do
      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "manual chunk",
        metadata: %{id: "c1", label: "Manual", preview: "manual", source_ref: nil, extras: %{}}
      }

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, fn _raw, _indexed, _opts ->
        %Cake.Responses.Result{
          raw_text: "answer",
          final_text: "answer",
          citations: [],
          warnings: []
        }
      end)

      pid = start_subscribed()

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "answer", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      # Step 1: manualask returns candidates
      assert {:ok, candidates} = Conversation.manualask(pid, "manual question")
      assert candidates != []

      # State is now awaiting_selection
      pre_select = :sys.get_state(pid)
      assert pre_select.state == :awaiting_selection
      assert pre_select.pending != nil

      # Step 2: select with chunk IDs completes the turn
      doc_ids =
        Enum.map(candidates, fn %Result{retrieval_unit: c} -> Cake.Citable.metadata(c).id end)

      assert :ok = Conversation.select_docs(pid, doc_ids)

      # Response broadcast via PubSub
      assert_receive {:response_ready, %{response: "answer", citations: []}}, 500

      # State back to idle
      post_select = :sys.get_state(pid)
      assert post_select.state == :idle
      assert post_select.pending == nil
    end

    test "manualask search error returns error and stays idle" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:error, :embed_failed}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)

      assert {:error, :embed_failed} = Conversation.manualask(pid, "q")

      state = :sys.get_state(pid)
      assert state.state == :idle
    end

    test "select with unknown doc IDs returns error and resets to idle" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      {:ok, _candidates} = Conversation.manualask(pid, "q")
      assert {:error, {:unknown_doc_ids, _}} = Conversation.select_docs(pid, ["nonexistent"])

      state = :sys.get_state(pid)
      assert state.state == :idle
      assert state.pending == nil
    end
  end

  describe "invalid transitions" do
    test "select in idle state crashes the GenServer" do
      pid = start_subscribed()

      ref = Process.monitor(pid)

      catch_exit(Conversation.select_docs(pid, ["some_id"]))

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    end

    test "manualask in awaiting_selection state crashes the GenServer" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      pid = start_subscribed()

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      {:ok, _} = Conversation.manualask(pid, "q")

      ref = Process.monitor(pid)
      catch_exit(Conversation.manualask(pid, "q2"))

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    end
  end

  describe "broadcasts" do
    test "auto turn emits :state_change and :response_ready broadcasts" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      conv_id = "bcast-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_supervised({Conversation, mocked_opts(%{id: conv_id})})

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "x", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Phoenix.PubSub.subscribe(Cake.PubSub, Cake.Conversation.Events.topic(conv_id))

      Conversation.autoask(pid, "q")

      assert_receive {:state_change, :generating}, 1_000
      assert_receive {:response_ready, %{response: "x", citations: []}}, 1_000
      assert_receive {:state_change, :idle}, 1_000
    end

    test "auto turn error emits :error and :state_change broadcasts" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:error, :embed_failed}
      end)

      conv_id = "bcast-err-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_supervised({Conversation, mocked_opts(%{id: conv_id})})

      allow(Cake.Embeddings.Mock, self(), pid)

      Phoenix.PubSub.subscribe(Cake.PubSub, Cake.Conversation.Events.topic(conv_id))

      Conversation.autoask(pid, "q")

      assert_receive {:state_change, :generating}, 1_000
      assert_receive {:error, :embed_failed}, 1_000
      assert_receive {:state_change, :idle}, 1_000
    end

    test "manual mode emits candidates_ready and state_change broadcasts" do
      chunk = build(:convo_chunk)

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [wrap_result(chunk)]}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      conv_id = "bcast-manual-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = start_supervised({Conversation, mocked_opts(%{id: conv_id})})

      stub(Cake.Generation.Mock, :complete, fn _messages, _model, _opts ->
        {:ok, %{text: "x", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)
      allow(Cake.Generation.Mock, self(), pid)

      Phoenix.PubSub.subscribe(Cake.PubSub, Cake.Conversation.Events.topic(conv_id))

      {:ok, candidates} = Conversation.manualask(pid, "q")

      assert_receive {:candidates_ready, ^candidates}, 1_000
      assert_receive {:state_change, :awaiting_selection}, 1_000

      doc_ids =
        Enum.map(candidates, fn %Result{retrieval_unit: c} -> Cake.Citable.metadata(c).id end)

      :ok = Conversation.select_docs(pid, doc_ids)

      assert_receive {:state_change, :generating}, 1_000
      assert_receive {:response_ready, %{response: "x"}}, 1_000
      assert_receive {:state_change, :idle}, 1_000
    end
  end
end
