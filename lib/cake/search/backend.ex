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

  @typedoc "Error reasons returned by Snap-backed operations."
  @type search_error :: Snap.ResponseError.t() | Snap.HTTPClient.Error.t() | Jason.DecodeError.t()

  @doc "Execute a search query and return matching hits."
  @callback search(Query.t()) :: {:ok, [Hit.t()]} | {:error, search_error()}

  @doc "Index (upsert) a document into a collection."
  @callback index_document(collection(), map(), String.t()) :: :ok | {:error, search_error()}

  @doc "Delete a document from a collection by ID."
  @callback delete_document(collection(), String.t()) :: :ok | {:error, search_error()}

  @doc "Create a collection with the given mapping/schema."
  @callback create_collection(collection(), map()) :: :ok | {:error, search_error()}

  @doc "List all collections in the deployment."
  @callback list_collections() :: {:ok, [String.t()]} | {:error, search_error()}

  @doc """
  The configured `Cake.Search.Backend` implementation.

  Reads `config :cake, :search_backend`, defaulting to
  `Cake.Search.Backend.OpenSearch`. No config file sets the key; tests inject
  the Mox mock with `Application.put_env/3`. `Cake.Search` and
  `Cake.Pipelines.add_to_search_backend/3` resolve the backend through this
  function on every call.
  """
  @spec backend() :: module()
  def backend do
    Application.get_env(:cake, :search_backend, Cake.Search.Backend.OpenSearch)
  end
end
