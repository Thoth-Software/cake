defmodule Cake.Search.Backend do
  @moduledoc """
  Behaviour for search backends (OpenSearch, Qdrant, etc.).

  Each backend translates `%Cake.Search.Query{}` into its native query
  format, executes it, and maps results back into `[%Cake.Search.Hit{}]`.
  Backends also handle document indexing and collection lifecycle.

  Injected via config, mockable with Mox.
  """

  alias Cake.Search.Hit
  alias Cake.Search.Query

  @type collection :: String.t()

  @doc "Execute a search query and return matching hits."
  @callback search(Query.t()) :: {:ok, [Hit.t()]} | {:error, term()}

  @doc "Index (upsert) a document into a collection."
  @callback index_document(collection(), map(), String.t()) :: :ok | {:error, term()}

  @doc "Delete a document from a collection by ID."
  @callback delete_document(collection(), String.t()) :: :ok | {:error, term()}

  @doc "Create a collection with the given mapping/schema."
  @callback create_collection(collection(), map()) :: :ok | {:error, term()}

  @doc "List all collections in the deployment."
  @callback list_collections() :: {:ok, [String.t()]} | {:error, term()}

  @spec backend() :: module()
  def backend do
    Application.get_env(:cake, :search_backend, Cake.Search.Backends.OpenSearch)
  end
end
