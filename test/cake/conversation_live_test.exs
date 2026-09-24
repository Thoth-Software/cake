defmodule Cake.ConversationLiveTest do
  @moduledoc """
  The full RAG loop through `Cake.Conversation` with every production
  collaborator live (#249, tier 2, item 9): a tiny corpus embedded by the
  real `Cake.Embeddings`, indexed into a real OpenSearch collection,
  retrieved and hydrated through the Books GDS, answered by the real
  `Cake.Generation.OpenAI` with the production response model, and cited
  by the real `Cake.Responses`. This is the staging-shaped smoke test
  #244 describes: the seed of the staging-branch merge gate.

  Tagged `:llm` (never `:integration`): `mix test --only llm` with
  `OPENAI_KEY` runs it, in CI the `llm` job, which for this suite also
  provides an OpenSearch service. The module repoints
  `Cake.Search.Deployment` at that cluster itself in `setup_all`, since
  only an integration run does so from `test_helper.exs`.

  ## Assertion policy

  Never the prose. What is pinned: the turn completes, its citations are
  non-empty and every one resolves to a chunk the turn actually retrieved
  from the seeded corpus, and every `[N]` left in the text is one of
  those citations (nothing hallucinated survives). For the decomposed
  case, additionally that every retrieved result carries decomposition
  provenance for both sub-questions. Each live turn is one embed, one
  search and one completion (plus one embed and one completion per
  sequential step), on the cheapest configured models.
  """

  use Cake.LiveLLMCase

  import Cake.SearchIntegrationCase, only: [integration_collection: 1]
  import Cake.ConversationIntegrationHelpers

  alias Cake.Conversation
  alias Cake.Search.Result

  # Generous: a live turn is several provider round trips.
  @turn_timeout :timer.seconds(120)

  # A strategy that emits the dependency edge no production strategy can
  # yet (README "Strategies and tiers"): the live part is every step's
  # embedding and generation, not the decomposition itself.
  defmodule SequentialDecomposition do
    @moduledoc false

    @behaviour Cake.Decomposition

    @impl Cake.Decomposition
    @spec decompose(String.t(), keyword()) :: {:ok, Cake.Decomposition.Result.t()}
    def decompose(question, _opts) do
      {:ok,
       Cake.Decomposition.Result.new(question, [
         %{question: "Which pump is fitted in the RO-400?", depends_on: []},
         %{question: "What is the warranty on that pump?", depends_on: [0]}
       ])}
    end
  end

  setup_all do
    start_live_deployment!()
    :ok
  end

  setup :integration_collection

  setup %{collection: collection} do
    %{corpus: seed_corpus!(collection, live_chunk_specs!(corpus_texts()))}
  end

  # A live turn is several provider round trips, far past the
  # assert_receive default the unit suites rely on, so the broadcast is
  # awaited with the turn's own bound; a turn error is reported as such
  # rather than as a timeout.
  defp run_turn!(pid, question) do
    assert :ok = Conversation.autoask(pid, question)

    outcome =
      receive do
        {:response_ready, %{response: response, citations: citations}} -> {response, citations}
        {:error, reason} -> flunk("the live turn failed: #{inspect(reason)}")
      after
        @turn_timeout -> flunk("no response within #{@turn_timeout}ms")
      end

    assert_receive {:state_change, :idle}
    outcome
  end

  # Every result the turn retrieved is a chunk of the seeded corpus.
  defp assert_retrieved_from_corpus(pid, corpus) do
    retrieved = GenServer.call(pid, :search_results)
    corpus_ids = Enum.map(corpus.chunks, & &1.id)

    assert retrieved != []
    assert Enum.all?(unit_ids(retrieved), &(&1 in corpus_ids))
    retrieved
  end

  # Every citation names a chunk the turn retrieved, with the book's own
  # label and download reference, and every marker left in the text is
  # one of the citations, numbered densely from 1.
  defp assert_resolvable_citations(retrieved, corpus, response, citations) do
    retrieved_ids = unit_ids(retrieved)
    assert citations != []

    for citation <- citations do
      assert citation.id in retrieved_ids
      assert citation.source_ref == corpus.book.source_file_path
      assert String.starts_with?(citation.label, corpus.book.title)
    end

    markers = response |> citation_markers() |> Enum.uniq() |> Enum.sort()
    assert markers == Enum.sort(Enum.map(citations, & &1.new_index))
    assert markers == Enum.to_list(1..length(citations))
  end

  describe "a plain live turn (decomposition: nil)" do
    test "answers with resolvable citations into the retrieved set", %{corpus: corpus} do
      pid = start_subscribed_conversation!(live_conversation_opts(corpus.gds))

      {response, citations} = run_turn!(pid, "Which booster pump is fitted in the RO-400?")

      retrieved = assert_retrieved_from_corpus(pid, corpus)
      assert_resolvable_citations(retrieved, corpus, response, citations)
      refute Enum.any?(retrieved, & &1.provenance.decomposed)
      assert length(:sys.get_state(pid).message_history) == 2
    end
  end

  describe "a sequential live turn" do
    test "resolves both steps live and answers with resolvable citations", %{corpus: corpus} do
      question = "What is the warranty on the pump fitted in the RO-400?"

      pid =
        start_subscribed_conversation!(
          live_conversation_opts(corpus.gds, %{decomposition: SequentialDecomposition})
        )

      {response, citations} = run_turn!(pid, question)

      retrieved = assert_retrieved_from_corpus(pid, corpus)
      assert_resolvable_citations(retrieved, corpus, response, citations)

      for %Result{provenance: provenance} <- retrieved do
        assert provenance.decomposed
        assert provenance.original_query == question
        assert provenance.sub_question_index in [0, 1]
      end

      assert retrieved
             |> Enum.map(& &1.provenance.sub_question_index)
             |> Enum.uniq()
             |> Enum.sort() ==
               [0, 1]
    end
  end
end
