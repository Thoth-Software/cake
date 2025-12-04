defmodule Caque.Documents.Cluster do
  @moduledoc """
  This maps to the cluster of indexes containing technical documents (for now, just one index)

  Eventyually, we'll need to define a Caque cluster behavior - possibly an
  extension of the Snap cluster behavior - that defines certain callbacks, e.g.
  the search function.
  """

  use Snap.Cluster, otp_app: :caque
  alias Snap.Indexes
  require Logger

  def build_mapping(schema) do
    embedding = %{
      type: "knn_vector",
      dimension: 1536,
      method: %{
        name: "hnsw",
        space_type: "cosinesimil",
        engine: "faiss"
      }
    }

    text_properties =
      schema.__schema__(:fields)
      |> Enum.reduce(%{}, fn field, acc ->
        case field do
          :text -> Map.merge(%{text: %{type: "text"}}, acc)
          :embedding -> Map.merge(%{embedding: embedding}, acc)
          keyword -> Map.merge(%{keyword => %{type: "keyword"}}, acc)
        end
      end)

    %{
      settings: %{"index.knn" => true},
      mappings: %{properties: text_properties}
    }
  end

  def start_convo(), do: start_convo(%{automatic: true})

  def start_convo(params) do
    case GenServer.start_link(Caque.Conversation, params) do
      {:ok, pid} -> pid
      error_tuple -> error_tuple
    end
  end

  def init(config) do
    Task.start_link(fn -> create_indexes_unless_exist(nil) end)
    {:ok, config}
  end

  # def init(config) do
  #   # Defer index creation to handle_continue to avoid blocking init.
  #   # This allows the cluster to start quickly and register its name
  #   # before attempting to create indexes.
  #   {:ok, config, {:continue, :create_indexes}}
  # end

  # def handle_continue(:create_indexes, config) do
  #   {:ok, task_pid} = Task.start_link(fn -> create_indexes_unless_exist(nil) end)
  #   {:noreply, Map.put(config, :index_creation_task, task_pid)}
  # end

  def create_indexes_unless_exist(nil) do
    Logger.debug("Document cluster not running yet.\n\nWaiting to create indexes...")
    Process.sleep(10_000)

    Process.whereis(__MODULE__)
    |> create_indexes_unless_exist()
  end

  def create_indexes_unless_exist(pid) when is_pid(pid) do
    __MODULE__
    |> Indexes.list()
    |> maybe_create_index()
    |> ensure_index_exists()
  end

  def enable_conversational_search(), do: nil

  # In this code snippet, we define a module `MyApp.Elasticsearch` that uses the `Snap.Elasticsearch` library. We then define a function `get_all_docs` that queries the Elasticsearch index named "docs" and retrieves all documents. The function constructs a query that matches all documents in the index and sets the size to 1000 to retrieve a large number of documents. It then extracts the source data from each hit in the response and returns a list of all documents.
  def all_documents() do
    query = %{query: %{match_all: %{}}}
    Snap.Search.search(__MODULE__, "docs", query)
  end

  # Food for thought: bespoke search functions for different clusters, or generalized search functions?
  # Answer: search functions ought to live on a given cluster, yes. But keep in
  # mind that clusters go to generic document types. Right now we have only one,
  # ParsedDoc, which implies only one set of search functions. However, if we
  # begin to have more than one generic, then we'll need search functions keyed
  # to that generic.
  #
  # Note that this also indicates searchability as a salient constraint on the
  # design of generic doc schemas.

  @spec search(:keyword | :vector | :hybrid, String.t(), %{
          keywords: List.t(),
          embedding: List.t(),
          keyword_weight: Float.t()
        }) :: {:ok, map()} | {:error, any()}
  def search(:keyword, index, %{keywords: keywords}) do
    query = %{
      query: %{
        multi_match: %{
          query: keywords,
          fields: ["title^2", "text"]
        }
      }
    }

    Snap.Search.search(__MODULE__, index, query)
  end

  def search(:vector, index, %{embedding: embedding}) do
    query = %{
      # usually same as k
      size: 10,
      query: %{
        knn: %{
          embedding: %{
            # MUST be a list of floats
            vector: embedding,
            k: 10
            # optional tuning for HNSW; remove or adjust as needed
            # rescore: true | %{oversample_factor: 8.0}  # optional
          }
        }
      }
    }

    Snap.Search.search(__MODULE__, index, query)
  end

  def search(:hybrid, index, %{
        keywords: keywords,
        embedding: embedding,
        keyword_weight: keyword_weight
      }) do
    # you can keep vector_weight around for later if you do fancy scoring
    # vector_weight = 1.0 - keyword_weight

    query = %{
      size: 10,
      query: %{
        bool: %{
          must: [
            # k-NN is the “core” query
            %{
              knn: %{
                embedding: %{
                  vector: embedding,
                  k: 10
                }
              }
            }
          ],
          # lexical query as a “should” clause that boosts docs
          should: [
            %{
              multi_match: %{
                query: keywords,
                fields: ["title^2", "text"],
                boost: keyword_weight
              }
            }
          ]
          # no minimum_should_match – knn must match, text is optional but boosts score
        }
      }
    }

    Snap.Search.search(__MODULE__, index, query)
  end

  def hits_text({:ok, %Snap.SearchResponse{hits: hits}}) do
    hits
    |> Enum.map(fn hit ->
      hit.source["text"]
    end)
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
