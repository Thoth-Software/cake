defmodule Cake.Documents.Cluster do
  @moduledoc """
  OpenSearch cluster managing all CAKE indices.
  Currently manages: "docs" (technical documentation) and "chunks_of_books" (book content).
  """

  use Snap.Cluster, otp_app: :cake
  alias Snap.Indexes
  require Logger

  def build_mapping(schema) do
    embedding = %{
      type: "knn_vector",
      dimension: 1536,
      method: %{
        name: "hnsw",
        space_type: "cosinesimil",
        engine: "faiss",
        parameters: %{
          ef_construction: 512,
          m: 16
        }
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
      settings: %{
        "index.knn" => true,
        "index.refresh_interval" => "30s",
        "index.merge.policy.max_merge_at_once" => 2
      },
      mappings: %{properties: text_properties}
    }
  end

  def start_convo(opts) do
    case Cake.Conversation.start_link(opts) do
      {:ok, pid} -> pid
      error_tuple -> error_tuple
    end
  end

  def init(config) do
    Task.start_link(fn -> create_indexes_unless_exist(nil) end)
    {:ok, config}
  end

  def create_indexes_unless_exist(nil) do
    Logger.debug("Cluster not running yet.\n\nWaiting to create indexes...")
    Process.sleep(10_000)

    Process.whereis(__MODULE__)
    |> create_indexes_unless_exist()
  end

  def create_indexes_unless_exist(pid) when is_pid(pid) do
    existing_indices = get_existing_indices()

    # Create both indices
    create_index_if_missing(existing_indices, "docs", Cake.Documents.ParsedDocument)
    create_index_if_missing(existing_indices, "chunks_of_books", Cake.Books.Chunk)
  end

  defp get_existing_indices() do
    case Indexes.list(__MODULE__) do
      {:ok, indices} -> indices
      {:error, error} -> raise error
    end
  end

  def enable_conversational_search(), do: nil

  def all_documents() do
    query = %{query: %{match_all: %{}}}
    Snap.Search.search(__MODULE__, "docs", query)
  end

  # TODO: Extract a `search_fields/0` callback into a behaviour, most likely on the
  # pipeline behaviours keyed to generics. Each schema (ParsedDocument, Chunk,
  # etc.) should declare which of its fields are searchable and how they should be
  # weighted, rather than requiring callers to pass a fields list. The search
  # function would then take a schema module as a parameter and call
  # schema.search_fields() to build the query. For now, callers pass `fields`
  # explicitly as a stopgap. 

  # Cake.Documents.Cluster.search(:keyword, "chunks_of_books")
  @spec search(:keyword | :vector | :hybrid, String.t(), %{
          keywords: List.t(),
          embedding: List.t(),
          keyword_weight: Float.t()
        }) :: {:ok, map()} | {:error, any()}
  def search(:keyword, index, %{keywords: keywords, fields: fields}) do
    query = %{
      query: %{
        multi_match: %{
          query: keywords,
          fields: fields
        }
      }
    }

    Snap.Search.search(__MODULE__, index, query)
  end

  def search(:vector, index, %{embedding: embedding}) do
    query = %{
      size: 10,
      query: %{
        knn: %{
          embedding: %{
            vector: embedding,
            k: 30
          }
        }
      }
    }

    Snap.Search.search(__MODULE__, index, query)
  end

  def search(:hybrid, index, %{
        keywords: keywords,
        fields: fields,
        embedding: embedding,
        keyword_weight: keyword_weight
      }) do
    query = %{
      size: 30,
      query: %{
        bool: %{
          must: [
            %{
              knn: %{
                embedding: %{
                  vector: embedding,
                  k: 30
                }
              }
            }
          ],
          should: [
            %{
              multi_match: %{
                query: keywords,
                fields: fields,
                boost: keyword_weight
              }
            }
          ]
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

  defp create_index_if_missing(existing_indices, index_name, schema) do
    case Enum.member?(existing_indices, index_name) do
      true ->
        Logger.info("Index '#{index_name}' already exists")
        {:ok, "Index already exists"}

      false ->
        Logger.info("Creating index '#{index_name}'...")
        result = Snap.Indexes.create(__MODULE__, index_name, build_mapping(schema))
        ensure_index_exists(result, index_name)
    end
  end

  defp ensure_index_exists({:error, %Snap.HTTPClient.Response{status: status, body: body}}, index) do
    raise "Transport-layer error creating index '#{index}': Status #{status}, Body: #{body}"
  end

  defp ensure_index_exists({:error, %Snap.ResponseError{status: status, message: message}}, index) do
    raise "Application error creating index '#{index}': Status #{status}, Message: #{message}"
  end

  defp ensure_index_exists({:error, %Jason.DecodeError{data: data}}, index) do
    raise "Application layer error within Cake instance creating index '#{index}' (cannot parse JSON) :\n\n Data: #{data}"
  end

  defp ensure_index_exists({:ok, _response}, index) do
    Logger.info("Successfully created index '#{index}'")
    :ok
  end

  defp ensure_index_exists(_, _index), do: :ok
end
