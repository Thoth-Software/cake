defmodule Cake.ConversationTest do
  @moduledoc """
  Characterization tests for `Cake.Conversation`. Pin current behavior so
  later refactors (PubSub migration, struct-arg refactor, etc.) preserve
  observable contracts.

  ## Why `Cake.Responses.Mock` instead of the real `Cake.Responses`

  Most "happy path" tests here mock `Cake.Responses` rather than calling
  through to the real implementation. The Conversation's job is to
  orchestrate Embeddings → Search → Generation → Responses → reply_to;
  pinning that orchestration is independent of pinning what the Responses
  pipeline does to a citation. The Responses module already has its own
  characterization coverage in `test/cake/responses_test.exs`.

  The exception is the citation-threading commit (Commit 5), which uses
  the real `Cake.Responses` so the metadata transformations through
  `process/3` are part of the pin.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Cake.Conversation
  alias Cake.Support.FixtureGDS
  alias Cake.Test.ConvoChunk
  alias Cake.Test.GenerationStub

  setup :verify_on_exit!

  defp valid_opts(overrides \\ %{}) do
    Map.merge(
      %{
        search: Cake.Search.OpenSearch,
        reply_to: self(),
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
        generation: Cake.Test.GenerationStub,
        responses: Cake.Responses.Mock
      })

    Map.merge(base, overrides)
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
    test "an :ok turn delivers a {:convo_response, _, _} message to reply_to" do
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
        {:ok, [{chunk, %{os_score: 1.0}}]}
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

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      :ok = GenerationStub.set_response(pid, {:ok, %{text: "answer", usage: %{}}})

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      assert :ok = Conversation.ask(pid, "what is two plus two?")

      assert_receive {:convo_response, _response, _citations}, 500
    end
  end

  describe "response shape" do
    test "{:convo_response, final_text, citations} — final_text is a string, citations is a list of maps with the documented keys" do
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
        {:ok, Enum.map(chunks, fn c -> {c, %{os_score: 1.0}} end)}
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

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_response(pid, {:ok, %{text: "answer [1] with [2] and [3]", usage: %{}}})

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      Conversation.ask(pid, "test question")

      assert_receive {:convo_response, response, citations}, 500

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

      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: marker,
        metadata: %{
          id: "c1",
          label: "L",
          preview: "p",
          source_ref: nil,
          extras: %{}
        }
      }

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [{chunk, %{os_score: 1.0}}]}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{
          raw_text: "ok",
          final_text: "ok",
          citations: [],
          warnings: []
        }
      end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      test_pid = self()

      GenerationStub.set_handler(pid, fn messages, _model ->
        send(test_pid, {:prompt_captured, messages})
        {:ok, %{text: "ok", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      Conversation.ask(pid, "q")

      assert_receive {:prompt_captured, messages}, 500

      serialized = Enum.map_join(messages, "\n", & &1.content)
      assert serialized =~ marker

      # Wait for the full turn to complete before the test exits, so Mox
      # verify_on_exit! sees the Responses.Mock invocation.
      assert_receive {:convo_response, _, _}, 500
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
        {:ok, Enum.map(chunks, fn c -> {c, %{os_score: 1.0}} end)}
      end)

      # NOTE: deliberately NOT mocking Cake.Responses — we want the real
      # process/3 so the citation transformations are part of the pin.
      {:ok, pid} =
        start_supervised({Conversation, mocked_opts(%{responses: Cake.Responses})})

      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_response(
        pid,
        {:ok, %{text: "answer references [2] and then [1].", usage: %{}}}
      )

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      Conversation.ask(pid, "q")

      assert_receive {:convo_response, _response, citations}, 500

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

      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "static chunk",
        metadata: %{id: "c1", label: "L", preview: "p", source_ref: nil, extras: %{}}
      }

      # `expect/3` with no count means exactly once across the test. If turn 2
      # called embed or search again, Mox would fail — that implicitly pins
      # "subsequent turns skip embed and search."
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [{chunk, %{os_score: 1.0}}]}
      end)

      expect(Cake.Responses.Mock, :process, 2, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      GenerationStub.set_handler(pid, fn messages, _model ->
        send(test_pid, {:prompt_captured, messages})
        call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        text = if call_num == 0, do: turn_one_a, else: "RESPONSE_TWO"
        {:ok, %{text: text, usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      Conversation.ask(pid, turn_one_q)
      assert_receive {:prompt_captured, turn_one_messages}, 500
      assert_receive {:convo_response, _, _}, 500

      Conversation.ask(pid, turn_two_q)
      assert_receive {:prompt_captured, turn_two_messages}, 500
      assert_receive {:convo_response, _, _}, 500

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

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_response(pid, {:ok, %{text: "x", usage: %{}}})

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      assert :ok = Conversation.ask(pid, "hello")

      assert_receive {:convo_response, _, _}, 500
    end

    test "print_hierarchy/2 returns a list (logging-only helper)" do
      assert is_list(Conversation.print_hierarchy(%{a: 1, b: %{c: 2}}))
    end
  end

  describe "cluster error" do
    test "cluster {:error, _} delivers {:convo_error, reason} to reply_to without crashing the GenServer" do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:error, :timeout}
      end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      ref = Process.monitor(pid)

      Conversation.ask(pid, "q")

      assert_receive {:convo_error, :timeout}, 500

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100

      state = :sys.get_state(pid)
      assert state.errors == [:timeout]
    end
  end

  describe "generation error" do
    test "generation {:error, _} delivers {:convo_error, reason} to reply_to without crashing" do
      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "x",
        metadata: %{id: "c1", label: "L", preview: "p", source_ref: nil, extras: %{}}
      }

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [{chunk, %{os_score: 1.0}}]}
      end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_response(pid, {:error, {:rate_limited, nil}})

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      ref = Process.monitor(pid)

      Conversation.ask(pid, "q")

      assert_receive {:convo_error, {:rate_limited, nil}}, 500
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

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_handler(pid, fn messages, _model ->
        send(test_pid, {:prompt_captured, messages})
        {:ok, %{text: "x", usage: %{}}}
      end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      Conversation.ask(pid, "q with no matching chunks")

      assert_receive {:prompt_captured, _messages}, 500
      assert_receive {:responses_indexed_chunks, indexed_chunks}, 500
      assert_receive {:convo_response, _, _}, 500

      assert indexed_chunks == []
    end
  end

  describe "uncited LLM output" do
    test "LLM text with no [N] markers yields citations: [] in the convo_response message" do
      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "x",
        metadata: %{id: "c1", label: "L", preview: "p", source_ref: nil, extras: %{}}
      }

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [{chunk, %{os_score: 1.0}}]}
      end)

      {:ok, pid} =
        start_supervised({Conversation, mocked_opts(%{responses: Cake.Responses})})

      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_response(
        pid,
        {:ok, %{text: "answer with no citation markers", usage: %{}}}
      )

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      Conversation.ask(pid, "q")

      assert_receive {:convo_response, response, citations}, 500

      assert is_binary(response)
      assert citations == []
    end
  end

  describe "push-message contract" do
    # The push-message contract IS the seam between Conversation and any
    # consumer (currently CakeWeb.ChatLive). The "polling interface" the
    # issue spec referenced does not exist — ChatLive uses
    # handle_info({:convo_response, _, _}, _) on a process Conversation
    # pushes to via send/2. These tests pin that seam by configuring a
    # distinct process as :reply_to and asserting the push lands there
    # (not in the caller's mailbox).

    setup do
      parent = self()

      reply_to =
        spawn_link(fn ->
          receive do
            msg -> send(parent, {:reply_to_received, msg})
          end
        end)

      {:ok, reply_to: reply_to}
    end

    test "successful turn pushes {:convo_response, _, _} to the configured reply_to, not the caller", %{reply_to: reply_to} do
      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "x",
        metadata: %{id: "c1", label: "L", preview: "p", source_ref: nil, extras: %{}}
      }

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [{chunk, %{os_score: 1.0}}]}
      end)

      expect(Cake.Responses.Mock, :process, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts(%{reply_to: reply_to})})
      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_response(pid, {:ok, %{text: "x", usage: %{}}})
      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)
      allow(Cake.Responses.Mock, self(), pid)

      Conversation.ask(pid, "q")

      assert_receive {:reply_to_received, {:convo_response, _response, _citations}}, 500
      refute_received {:convo_response, _, _}
    end

    test "failed turn pushes {:convo_error, reason} to the configured reply_to, not the caller", %{reply_to: reply_to} do
      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:error, :boom}
      end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts(%{reply_to: reply_to})})
      on_exit(fn -> GenerationStub.clear(pid) end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      Conversation.ask(pid, "q")

      assert_receive {:reply_to_received, {:convo_error, :boom}}, 500
      refute_received {:convo_error, _}
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

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      allow(Cake.Embeddings.Mock, self(), pid)
      allow(Cake.Search.Mock, self(), pid)

      ref = Process.monitor(pid)

      Conversation.ask(pid, "q")

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 500

      assert match?({%RuntimeError{message: "boom"}, _stacktrace}, reason)

      refute_received {:convo_response, _, _}
      refute_received {:convo_error, _}
    end
  end

  describe "concurrent asks" do
    test "two ask/2 calls are serialized by the GenServer mailbox: cast 2 cannot start until cast 1 returns" do
      chunk = %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "x",
        metadata: %{id: "c1", label: "L", preview: "p", source_ref: nil, extras: %{}}
      }

      expect(Cake.Embeddings.Mock, :embed, fn _, _, _ ->
        {:ok, %{attrs: %{embedding: [0.1, 0.2, 0.3]}}}
      end)

      expect(Cake.Search.Mock, :search_chunks_with_context, fn _, _, _, _, _ ->
        {:ok, [{chunk, %{os_score: 1.0}}]}
      end)

      expect(Cake.Responses.Mock, :process, 2, fn _, _, _ ->
        %Cake.Responses.Result{raw_text: "x", final_text: "x", citations: [], warnings: []}
      end)

      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {:ok, pid} = start_supervised({Conversation, mocked_opts()})
      on_exit(fn -> GenerationStub.clear(pid) end)

      GenerationStub.set_handler(pid, fn _messages, _model ->
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

      assert :ok = Conversation.ask(pid, "q1")
      assert :ok = Conversation.ask(pid, "q2")

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
      assert_receive {:convo_response, _, _}, 500
      assert_receive {:convo_response, _, _}, 500
    end
  end
end
