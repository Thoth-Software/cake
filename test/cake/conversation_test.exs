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
end
