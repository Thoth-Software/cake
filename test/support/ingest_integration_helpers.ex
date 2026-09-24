defmodule Cake.IngestIntegrationHelpers do
  @moduledoc """
  Helpers for the end-to-end ingestion tests (#248): a fixture PDF in, a
  searchable chunk out, through the real NIF, real Postgres, the real
  `Cake.Embeddings.Mock` collaborator, and a real OpenSearch node.

  Every function here is a stub that raises: the tests were written against
  this API first, and the green commit fills the bodies in.
  """

  @type embedding_response :: [float()] | {:error, String.t()}

  @spec stage_book_storage!(map()) :: %{book_storage_root: Path.t()}
  def stage_book_storage!(_context), do: not_implemented(:stage_book_storage!, 1)

  @spec ensure_collection!(module()) :: :ok
  def ensure_collection!(_gds), do: not_implemented(:ensure_collection!, 1)

  @spec stage_fixture!(Cake.PdfFixtures.name()) :: Cake.Books.Adapters.key()
  def stage_fixture!(_name), do: not_implemented(:stage_fixture!, 1)

  @spec embedding_model() :: String.t()
  def embedding_model, do: not_implemented(:embedding_model, 0)

  @spec deterministic_embedding(String.t()) :: [float()]
  def deterministic_embedding(_text), do: not_implemented(:deterministic_embedding, 1)

  @spec embed_input(Cake.Books.Chunk.t() | Cake.Documents.ParsedDocument.t()) :: String.t()
  def embed_input(_record), do: not_implemented(:embed_input, 1)

  @spec stub_embeddings((String.t() -> embedding_response())) :: :ok
  def stub_embeddings(_on_input \\ &deterministic_embedding/1),
    do: not_implemented(:stub_embeddings, 1)

  @spec chunks_in_order(Cake.Books.ParsedBook.t()) :: [Cake.Books.Chunk.t()]
  def chunks_in_order(_book), do: not_implemented(:chunks_in_order, 1)

  defp not_implemented(name, arity) do
    raise "Cake.IngestIntegrationHelpers.#{name}/#{arity} is not implemented yet (#248)"
  end
end
