defmodule Cake.ConversationIntegrationHelpers do
  @moduledoc """
  Helpers for driving a `Cake.Conversation` through the full per-turn
  pipeline against a real search cluster (#249): a real-index corpus of
  `Cake.Books.Chunk` rows with fixed embedding vectors, a `Cake.GDS`
  module bound to the test's own collection, deterministic Mox embeddings,
  and `Req.Test`-scripted generation through the real
  `Cake.Generation.OpenAI` transport.

  Every function is a stub until #249 item 2 lands: each raises so the
  tier-1 tests fail for the right reason (missing wiring) rather than
  failing to compile.
  """

  @not_implemented "not implemented yet (#249 item 2)"

  @typedoc "One chunk of the corpus: its text and the unit-vector axis it embeds on."
  @type chunk_spec :: %{required(:text) => String.t(), required(:axis) => non_neg_integer()}

  @typedoc "A seeded corpus: the book, its chunks (book preloaded), and the GDS bound to the collection."
  @type corpus :: %{
          book: Cake.Books.ParsedBook.t(),
          chunks: [Cake.Books.Chunk.t()],
          gds: module()
        }

  @typedoc "The messages list `Cake.Generation.OpenAI` posted, decoded from the request body."
  @type wire_messages :: [%{String.t() => String.t()}]

  @spec seed_corpus!(String.t(), [chunk_spec()]) :: corpus()
  def seed_corpus!(_collection, _specs), do: raise(@not_implemented)

  @spec collection_gds(String.t()) :: module()
  def collection_gds(_collection), do: raise(@not_implemented)

  @spec blend_vector([{non_neg_integer(), float()}]) :: [float()]
  def blend_vector(_weights), do: raise(@not_implemented)

  @spec embedding_result([float()]) :: {:ok, Cake.Embeddings.Behaviour.embedding_result()}
  def embedding_result(_vector), do: raise(@not_implemented)

  @spec conversation_opts(module(), map()) :: map()
  def conversation_opts(_gds, _overrides \\ %{}), do: raise(@not_implemented)

  @spec start_subscribed_conversation!(map()) :: pid()
  def start_subscribed_conversation!(_opts), do: raise(@not_implemented)

  @spec script_generation!((wire_messages() -> String.t())) :: :ok
  def script_generation!(_fun), do: raise(@not_implemented)

  @spec citation_markers(String.t()) :: [pos_integer()]
  def citation_markers(_text), do: raise(@not_implemented)

  @spec unit_ids([Cake.Search.Result.t()] | [Cake.Prompt.indexed_chunk()]) :: [String.t()]
  def unit_ids(_results), do: raise(@not_implemented)
end
