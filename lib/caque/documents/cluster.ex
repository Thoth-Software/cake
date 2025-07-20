defmodule Caque.Documents.Cluster do
  @moduledoc """
  This maps to the cluster of indexes containing technical documents (for now, just one index)
  """

  use Snap.Cluster, otp_app: :caque
  alias Snap.Indexes
  require Logger

  def build_mapping(schema) do
    vector_properties = %{
      embedding: %{
        type: "knn_vector",
        dimension: 1536,
        method: %{
          name: "hnsw",
          space_type: "cosinesimil",
          engine: "nmslib"
        }
      }
    }

    text_properties =
      schema.__schema__(:fields)
      |> Enum.reduce(%{}, fn field, acc ->
        case field do
          :text -> Map.merge(%{text: %{type: "text"}}, acc)
          keyword -> Map.merge(%{keyword => %{type: "keyword"}}, acc)
        end
      end)

    %{
      settings: %{"index.knn" => true},
      mappings: %{properties: Map.merge(vector_properties, text_properties)}
    }
  end

  def init(config) do
    Task.start_link(fn -> create_indexes_unless_exist(nil) end)
    {:ok, config}
  end

  def create_indexes_unless_exist(nil) do
    Logger.debug("Document cluster not running yet.\n\nWaiting to create indexes...")
    Process.sleep(10_000)

    Process.whereis(__MODULE__)
    |> create_indexes_unless_exist()
  end

  def create_indexes_unless_exist(_) do
    __MODULE__
    |> Indexes.list()
    |> maybe_create_index()
    |> ensure_index_exists()
  end

  def get_all_docs do
    index = "docs"
    query = %{"query" => %{"match_all" => %{}}, "size" => 1000}

    {:ok, response} = Snap.Search.search(__MODULE__, index, query)

    hits = response.hits["hits"]

    Enum.map(hits, fn hit ->
      hit["_source"]
    end)
  end

# In this code snippet, we define a module `MyApp.Elasticsearch` that uses the `Snap.Elasticsearch` library. We then define a function `get_all_docs` that queries the Elasticsearch index named "docs" and retrieves all documents. The function constructs a query that matches all documents in the index and sets the size to 1000 to retrieve a large number of documents. It then extracts the source data from each hit in the response and returns a list of all documents.
  def all_documents() do
    query = %{query: %{match_all: %{}}}
    Snap.Search.search(__MODULE__, "docs", query)
  end

  defp maybe_create_index({:error, error}), do: raise(error)

  defp maybe_create_index({:ok, existing_index}) do
    index = "docs"

    case Enum.member?(existing_index, index) do
      true ->
        {:ok, "Document cluster already running"}

      _ ->
        Snap.Indexes.create(__MODULE__, index, build_mapping(Caque.Documents.ParsedDocument))
    end
  end

  defp ensure_index_exists({:error, %Snap.HTTPClient.Response{status: status, body: body}}) do
    raise "Transport-layer error between app and Snap server: #{__MODULE__}\n\nReturn status: #{status} \n\n body: #{body}}"
  end

  defp ensure_index_exists({:error, %Snap.ResponseError{status: status, message: message}}) do
    raise "Application error within Snap instance:\n\n Status: #{status} \n\n Message: #{message}"
  end

  defp ensure_index_exists({:error, %Jason.DecodeError{data: data}}) do
    raise "Application layer error within Caque instance (cannot parse JSON) :\n\n Data: #{data}"
  end

  defp ensure_index_exists(_) do
    nil
  end
end
