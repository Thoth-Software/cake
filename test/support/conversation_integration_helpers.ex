defmodule Cake.ConversationIntegrationHelpers do
  @moduledoc """
  Helpers for driving a `Cake.Conversation` through the full per-turn
  pipeline against a real search cluster (#249): a real-index corpus of
  `Cake.Books.Chunk` rows with fixed embedding vectors, a `Cake.GDS`
  module bound to the test's own collection, deterministic Mox embeddings,
  and `Req.Test`-scripted generation through the real
  `Cake.Generation.OpenAI` transport.

  Import into a test on `Cake.SearchIntegrationCase` (the collection,
  `refresh!/1` and `unit_vector/1` come from there). Mox expectations stay
  in the tests; the helpers only build the values they return.

  ## The per-collection GDS

  `Cake.Conversation` reaches the index through `gds.collection_name/0`,
  and the Books GDS names its fixed production collection. Each test
  needs its own, so `collection_gds/1` points `CollectionGDS` — a
  `Cake.GDS` that reads its collection name from application config and
  delegates hydration and neighbor expansion to `Cake.Books.ParsedBook` —
  at the test's collection for the test's duration. The config is global
  to the VM, which is one reason the suites on these helpers are
  `async: false` (the shared Ecto sandbox is the other).

  ## Ownership across the turn task

  Every slow stage of a turn runs in a task under `Cake.TaskSupervisor`,
  whose `$callers` chain leads back to the conversation pid, not to the
  test. `start_subscribed_conversation!/1` therefore allows the
  conversation pid on every Mox mock and on the `Req.Test` plug, and the
  chain covers the tasks (and the flat fan-out's sub-tasks) underneath.
  """

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Citable
  alias Cake.Conversation
  alias Cake.Conversation.Events
  alias Cake.ConversationIntegrationHelpers.CollectionGDS
  alias Cake.Pipelines
  alias Cake.Repo
  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Result
  alias Cake.SearchIntegrationCase

  @generation_transport Cake.Generation.OpenAI
  @mocks [
    Cake.Embeddings.Mock,
    Cake.Generation.Mock,
    Cake.Decomposition.Mock,
    Cake.Responses.Mock
  ]

  @typedoc """
  One chunk of the corpus: its text, embedded on a unit-vector `axis` or
  with an explicit `embedding` (the live tier embeds for real).
  """
  @type chunk_spec ::
          %{required(:text) => String.t(), required(:axis) => non_neg_integer()}
          | %{required(:text) => String.t(), required(:embedding) => [float()]}

  @typedoc "A seeded corpus: the book, its chunks (book preloaded), and the GDS bound to the collection."
  @type corpus :: %{
          book: ParsedBook.t(),
          chunks: [Chunk.t()],
          gds: module()
        }

  @typedoc "The messages list `Cake.Generation.OpenAI` posted, decoded from the request body."
  @type wire_messages :: [%{String.t() => String.t()}]

  # The standard three-chunk corpus every conversation suite seeds. No
  # token of the questions the suites ask appears in the filter chunk, so
  # its BM25 contribution is zero and it is always the lowest-scored hit.
  @corpus_texts [
    pump: "The RO-400 reverse osmosis unit is fitted with the P-100 booster pump.",
    warranty: "Every P-100 booster pump carries a five-year limited warranty.",
    filter: "Sediment prefilter cartridges should be replaced every six months."
  ]

  @typedoc "A chunk of the standard corpus, by role."
  @type corpus_chunk :: :pump | :warranty | :filter

  @doc "The standard corpus texts in seeding order: pump, warranty, filter."
  @spec corpus_texts() :: [String.t()]
  def corpus_texts, do: Keyword.values(@corpus_texts)

  @doc "The text of one chunk of the standard corpus."
  @spec corpus_text(corpus_chunk()) :: String.t()
  def corpus_text(chunk) when is_atom(chunk), do: Keyword.fetch!(@corpus_texts, chunk)

  @doc """
  Named setup that seeds the standard corpus into the test's collection
  with chunk `i` on unit-vector axis `i`: pump on 0, warranty on 1,
  filter on 2. Adds the corpus and the three chunks to the context.

      setup :seed_standard_corpus
  """
  @spec seed_standard_corpus(map()) :: %{
          corpus: corpus(),
          pump: Chunk.t(),
          warranty: Chunk.t(),
          filter: Chunk.t()
        }
  def seed_standard_corpus(%{collection: collection}) do
    specs = Enum.with_index(corpus_texts(), fn text, axis -> %{text: text, axis: axis} end)
    corpus = seed_corpus!(collection, specs)
    [pump, warranty, filter] = corpus.chunks
    %{corpus: corpus, pump: pump, warranty: warranty, filter: filter}
  end

  @doc """
  Creates `collection` with the Books mapping, inserts one `ParsedBook`
  with one `Chunk` per spec (in order, so chunk `i` has `chunk_index: i`),
  indexes every chunk through `Cake.Pipelines.add_to_search_backend/3`
  and refreshes the collection. Raises if the server rejected any chunk.
  Returns the book, the chunks with `:parsed_book` preloaded, and the
  GDS bound to the collection.
  """
  @spec seed_corpus!(String.t(), [chunk_spec()]) :: corpus()
  def seed_corpus!(collection, specs) when is_binary(collection) and is_list(specs) do
    :ok = OpenSearch.create_collection(collection, OpenSearch.build_mapping(Chunk))

    {book, chunks} = Cake.BooksFixtures.book_with_chunks_fixture(Enum.map(specs, &chunk_attrs/1))

    indexed =
      chunks
      |> Pipelines.add_to_search_backend(collection, pipeline_context())
      |> Enum.to_list()

    if length(indexed) != length(chunks) do
      raise "the cluster rejected #{length(chunks) - length(indexed)} of #{length(chunks)} chunks"
    end

    SearchIntegrationCase.refresh!(collection)

    %{book: book, chunks: Repo.preload(chunks, :parsed_book), gds: collection_gds(collection)}
  end

  defp chunk_attrs(%{text: text, axis: axis}) when is_binary(text) do
    %{text: text, embedding: SearchIntegrationCase.unit_vector(axis)}
  end

  defp chunk_attrs(%{text: text, embedding: embedding})
       when is_binary(text) and is_list(embedding) do
    %{text: text, embedding: embedding}
  end

  defp pipeline_context do
    Pipelines.build_context(Cake.Books.Pipeline, Cake.Books.Pdf.Pipeline, "conversation-it")
  end

  @doc """
  The `Cake.GDS` module bound to `collection` for the rest of the test:
  `CollectionGDS`, with its collection name set in application config
  and cleared again in `on_exit`. Call from the test process.
  """
  @spec collection_gds(String.t()) :: module()
  def collection_gds(collection) when is_binary(collection) do
    Application.put_env(:cake, CollectionGDS.config_key(), collection)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:cake, CollectionGDS.config_key()) end)
    CollectionGDS
  end

  defmodule CollectionGDS do
    @moduledoc """
    The Books GDS over a test's own collection: `collection_name/0` reads
    the name `Cake.ConversationIntegrationHelpers.collection_gds/1` put in
    application config, and everything else is `Cake.Books.ParsedBook`'s.
    Raises when no collection is configured, so a test that forgot the
    helper fails at the first search rather than reaching the production
    `chunks_of_books` collection.
    """

    use Cake.GDS

    @config_key :conversation_integration_collection

    @doc "The application config key holding the collection name."
    @spec config_key() :: atom()
    def config_key, do: @config_key

    @impl Cake.GDS
    @spec collection_name() :: String.t()
    def collection_name, do: Application.fetch_env!(:cake, @config_key)

    @impl Cake.GDS
    @spec search_fields() :: [String.t()]
    def search_fields, do: ParsedBook.search_fields()

    @impl Cake.GDS
    @spec load_from_hits([Cake.Search.Hit.t()]) :: [struct()]
    defdelegate load_from_hits(hits), to: ParsedBook

    @impl Cake.GDS
    @spec expand_with_neighbors([struct()], non_neg_integer()) :: [struct()]
    defdelegate expand_with_neighbors(units, offset), to: ParsedBook
  end

  @doc """
  A vector in the configured embedding dimension with `weight` on each
  listed `axis` and 0.0 everywhere else — a query that is close to
  several corpus chunks at once, in a known order. Raises for an axis the
  dimension does not have, like `Cake.SearchIntegrationCase.unit_vector/1`.
  """
  @spec blend_vector([{non_neg_integer(), number()}]) :: [float()]
  def blend_vector(weights) when is_list(weights) do
    dimension = Application.get_env(:cake, :default_embedding_dimension, 1536)

    Enum.reduce(weights, List.duplicate(0.0, dimension), fn {axis, weight}, vector ->
      if axis >= dimension do
        raise ArgumentError,
              "axis #{axis} is outside the embedding dimension #{dimension} (axes run 0..#{dimension - 1})"
      end

      List.update_at(vector, axis, &(&1 + weight * 1.0))
    end)
  end

  @doc "The `{:ok, result}` a `Cake.Embeddings.Behaviour` implementation returns for `vector`."
  @spec embedding_result([float()]) :: {:ok, Cake.Embeddings.Behaviour.embedding_result()}
  def embedding_result(vector) when is_list(vector) do
    {:ok,
     %{
       usage: %{"prompt_tokens" => 0, "total_tokens" => 0},
       struct: nil,
       attrs: %{embedding: vector}
     }}
  end

  @doc """
  Opts for `Cake.Conversation.start_link/1`: the production
  `Cake.Conversation` config (embedder, response model, provider) with a
  unique id, `gds` in place of the production GDS, Mox embeddings, the
  real `Cake.Generation.OpenAI` transport (scripted through `Req.Test`)
  and the real `Cake.Responses`. `overrides` win.
  """
  @spec conversation_opts(module(), map()) :: map()
  def conversation_opts(gds, overrides \\ %{}) when is_atom(gds) and is_map(overrides) do
    :cake
    |> Application.fetch_env!(Conversation)
    |> Map.new()
    |> Map.merge(%{
      id: "conversation-it-#{System.unique_integer([:positive])}",
      gds: gds,
      embeddings: Cake.Embeddings.Mock,
      generation: @generation_transport,
      responses: Cake.Responses
    })
    |> Map.merge(overrides)
  end

  @doc """
  Starts a conversation under the test supervisor, subscribes the calling
  test process to its `Cake.Conversation.Events` topic, and allows the
  conversation pid (and so its turn tasks) on every Mox mock and on the
  `Cake.Generation.OpenAI` `Req.Test` plug. A test that never scripts
  generation gets a plug that fails the request loudly instead.
  """
  @spec start_subscribed_conversation!(map()) :: pid()
  def start_subscribed_conversation!(%{id: id} = opts) do
    pid = ExUnit.Callbacks.start_supervised!({Conversation, opts})
    attach!(pid, id)
  end

  # Subscribes the calling test to the conversation's topic and allows
  # the conversation pid — and so its turn tasks — on every collaborator.
  defp attach!(pid, id) do
    :ok = Phoenix.PubSub.subscribe(Cake.PubSub, Events.topic(id))
    Enum.each(@mocks, &Mox.allow(&1, self(), pid))
    allow_generation_transport!(pid)
    pid
  end

  # Req.Test only allows a pid from a process that already holds the
  # plug, so a test that has not scripted generation yet gets the loud
  # default installed first; script_generation!/1 replaces it in place
  # and the allowance stands.
  defp allow_generation_transport!(pid) do
    case Req.Test.allow(@generation_transport, self(), pid) do
      :ok ->
        :ok

      {:error, %{reason: :not_allowed}} ->
        Req.Test.stub(@generation_transport, &unscripted_generation/1)
        :ok = Req.Test.allow(@generation_transport, self(), pid)
    end
  end

  defp unscripted_generation(_conn) do
    raise "Cake.Generation.OpenAI was called but no generation is scripted: " <>
            "call Cake.ConversationIntegrationHelpers.script_generation!/1 first"
  end

  @doc """
  Scripts what the model says: installs a `Req.Test` plug for
  `Cake.Generation.OpenAI` that decodes the posted messages list, hands it
  to `fun`, and answers with a completed Responses API body carrying the
  text `fun` returns — so the real transport, parser and usage
  normalization run on every turn. The plug runs in the calling task, so
  `fun` may send the messages to the test process for assertions.
  """
  @spec script_generation!((wire_messages() -> String.t())) :: :ok
  def script_generation!(fun) when is_function(fun, 1) do
    Req.Test.stub(@generation_transport, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => messages} = Jason.decode!(body)
      Req.Test.json(conn, responses_api_body(fun.(messages)))
    end)

    :ok
  end

  @doc "A completed OpenAI Responses API body whose only output is `text`."
  @spec responses_api_body(String.t()) :: map()
  def responses_api_body(text) when is_binary(text) do
    %{
      "output" => [
        %{
          "type" => "message",
          "status" => "completed",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
        }
      ],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
      "model" => "scripted"
    }
  end

  @doc """
  How many search requests the cluster has served for `collection` so
  far (its `query_total` search stat): the backend-call-absence check a
  real backend allows — read it before and after a turn that must not
  retrieve.
  """
  @spec search_request_count!(String.t()) :: non_neg_integer()
  def search_request_count!(collection) when is_binary(collection) do
    # Raw path, so the index name carries the Snap namespace itself.
    path = "/#{SearchIntegrationCase.index_namespace()}-#{collection}/_stats/search"

    case Cake.Search.Deployment.get(path) do
      {:ok, %{"_all" => %{"total" => %{"search" => %{"query_total" => count}}}}} -> count
      {:error, error} -> raise "search stats for #{collection} failed: #{inspect(error)}"
    end
  end

  @self_ask_final_marker "So the final answer is:"

  @typedoc "A messages list as posted over the wire (string keys) or as a Mox mock received it (atom keys)."
  @type any_messages :: wire_messages() | [Cake.Generation.message()]

  @doc "A `Cake.Decomposition.Result` marked `:self_ask`, as only a strategy module can mark it."
  @spec self_ask_result(String.t()) :: Cake.Decomposition.Result.t()
  def self_ask_result(question) when is_binary(question) do
    %Cake.Decomposition.Result{original_question: question, strategy: :self_ask}
  end

  @doc "A `Cake.Decomposition.Result` marked `:ircot`, as only a strategy module can mark it."
  @spec ircot_result(String.t()) :: Cake.Decomposition.Result.t()
  def ircot_result(question) when is_binary(question) do
    %Cake.Decomposition.Result{original_question: question, strategy: :ircot}
  end

  @doc "Whether `messages` is a self-ask driver prompt (its system message teaches the final-answer marker)."
  @spec driver_prompt?(any_messages()) :: boolean()
  def driver_prompt?([system | _rest]) do
    String.contains?(message_content(system), @self_ask_final_marker)
  end

  @doc "Every message's content in `messages`, joined by newlines, whichever key shape it has."
  @spec prompt_text(any_messages()) :: String.t()
  def prompt_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", &message_content/1)
  end

  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(%{content: content}) when is_binary(content), do: content

  @doc """
  Points the `Cake.Conversation` application config `CakeWeb.ChatLive`
  starts conversations from at `gds`, with Mox embeddings, for the rest
  of the test; the previous config comes back in `on_exit`.
  """
  @spec configure_chat_conversation!(module()) :: :ok
  def configure_chat_conversation!(gds) when is_atom(gds) do
    previous = Application.fetch_env!(:cake, Conversation)

    Application.put_env(
      :cake,
      Conversation,
      Keyword.merge(previous,
        gds: gds,
        embeddings: Cake.Embeddings.Mock,
        generation: @generation_transport,
        responses: Cake.Responses
      )
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:cake, Conversation, previous) end)
    :ok
  end

  @doc """
  The conversation a mounted `CakeWeb.ChatLive` owns: subscribes the
  calling test to its topic and allows it on every mock and the `Req.Test`
  plug, exactly like `start_subscribed_conversation!/1` does for a
  conversation the test started itself. Returns its pid.
  """
  @spec attach_to_chat_conversation!(Phoenix.LiveViewTest.View.t()) :: pid()
  def attach_to_chat_conversation!(%Phoenix.LiveViewTest.View{pid: view_pid}) do
    %{socket: %{assigns: %{convo_pid: pid}}} = :sys.get_state(view_pid)
    %{id: id} = :sys.get_state(pid)
    attach!(pid, id)
  end

  @doc """
  Repoints `Cake.Search.Deployment` at the real cluster for the rest of
  an `mix test --only llm` run, the way `test_helper.exs` does for an
  integration run, so a live suite can seed and search a real index.
  Call from `setup_all`. Refuses any other run shape: the swap is global
  to the VM and would leave later unit tests on the real cluster.
  """
  @spec start_live_deployment!() :: :ok
  def start_live_deployment! do
    config = ExUnit.configuration()

    unless llm_only_run?(Keyword.get(config, :include, []), Keyword.get(config, :exclude, [])) do
      raise ArgumentError, """
      the live conversation suite repoints Cake.Search.Deployment at a real \
      cluster for the rest of the run, which only an exclusive `mix test \
      --only llm` run can absorb (the Deployment config is global to the VM). \
      Run it with `OPENAI_KEY=... mix test --only llm`, not `--include llm`.\
      """
    end

    SearchIntegrationCase.start_real_deployment!()
  end

  # The shape mix gives `--only llm`: the tag included, `:test` excluded.
  defp llm_only_run?(include, exclude) do
    tagged?(include, :llm) and tagged?(exclude, :test)
  end

  defp tagged?(filters, tag) do
    Enum.any?(filters, fn
      ^tag -> true
      {^tag, _value} -> true
      _other -> false
    end)
  end

  @doc """
  Corpus specs for `seed_corpus!/2` whose vectors come from the real
  embeddings endpoint, with the configured embedding model, one call per
  text. Raises on any provider error.
  """
  @spec live_chunk_specs!([String.t()]) :: [chunk_spec()]
  def live_chunk_specs!(texts) when is_list(texts) do
    model = Application.get_env(:cake, :default_embedding_model, "text-embedding-ada-002")

    Enum.map(texts, fn text ->
      case Cake.Embeddings.embed(:openai, %{input: text}, model) do
        {:ok, %{attrs: %{embedding: embedding}}} -> %{text: text, embedding: embedding}
        {:error, reason} -> raise "embedding the corpus live failed: #{inspect(reason)}"
      end
    end)
  end

  @doc """
  `conversation_opts/2` with the production collaborators in place of the
  test doubles: the real `Cake.Embeddings`, `Cake.Generation.OpenAI` and
  `Cake.Responses`. `overrides` win.
  """
  @spec live_conversation_opts(module(), map()) :: map()
  def live_conversation_opts(gds, overrides \\ %{}) when is_atom(gds) and is_map(overrides) do
    live = %{
      embeddings: Cake.Embeddings,
      generation: @generation_transport,
      responses: Cake.Responses
    }

    conversation_opts(gds, Map.merge(live, overrides))
  end

  @doc "The `[N]` citation markers in `text`, in order of appearance, duplicates kept."
  @spec citation_markers(String.t()) :: [pos_integer()]
  def citation_markers(text) when is_binary(text) do
    ~r/\[(\d+)\]/
    |> Regex.scan(text)
    |> Enum.map(fn [_whole, n] -> String.to_integer(n) end)
  end

  @doc """
  The Citable ids of the retrieval units in `results` — a list of
  `Cake.Search.Result` structs or of `Cake.Prompt` indexed chunks — in
  list order.
  """
  @spec unit_ids([Result.t()] | [Cake.Prompt.indexed_chunk()]) :: [String.t()]
  def unit_ids(results) when is_list(results), do: Enum.map(results, &unit_id/1)

  defp unit_id({_index, %Result{} = result}), do: unit_id(result)
  defp unit_id(%Result{retrieval_unit: unit}), do: Citable.metadata(unit).id
end
