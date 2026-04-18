defmodule Cake.Search do
  @moduledoc """
  Behaviour defining the search contract for the application.

  The real implementation is `Cake.Search.OpenSearch`. In tests: `Cake.Search.Mock` (Mox).

  Callers receive the implementation module as an injected argument, following the same
  pattern as `cluster` injection into `Conversation`.
  """

  @type search_type :: :keyword | :vector | :hybrid
  @type search_opts :: keyword()
  @type search_result :: {:ok, Snap.SearchResponse.t()} | {:error, any()}

  @doc "Execute an arbitrary `%Cake.Search.Query{}` against the cluster."
  @callback search(Cake.Search.Query.t()) :: search_result()

  @doc """
  Search for book chunks. Returns raw OpenSearch hits.
  `embedding` may be nil for keyword-only search.
  """
  @callback search_chunks(search_type(), String.t(), [float()] | nil, search_opts()) ::
              search_result()

  @doc """
  Search for book chunks and expand results with neighboring chunks from Postgres.
  Returns `[%Cake.Books.Chunk{}]` with `:parsed_book` preloaded.
  `expand` is the neighbor offset (e.g. 2 means fetch 2 chunks on each side of every hit).
  """
  @callback search_chunks_with_context(
              search_type(),
              String.t(),
              [float()] | nil,
              non_neg_integer(),
              search_opts()
            ) :: {:ok, [Cake.Books.Chunk.t()]} | {:error, any()}

  @doc "Search for parsed documents (programming docs). Same signature shape as `search_chunks/4`."
  @callback search_docs(search_type(), String.t(), [float()] | nil, search_opts()) ::
              search_result()
end
