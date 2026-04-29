defmodule Cake.Documents.Cluster do
  @moduledoc """
  OpenSearch cluster managing all CAKE indices.
  Currently manages: "docs" (technical documentation) and "chunks_of_books" (book content).
  """

  use Snap.Cluster, otp_app: :cake
  alias Snap.Indexes
  require Logger

  @spec build_mapping(module()) :: map()
  def build_mapping(schema) do
    embedding = %{
      type: "knn_vector",
      dimension: Application.fetch_env!(:cake, :default_embedding_dimension),
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
      Enum.reduce(schema.__schema__(:fields), %{}, fn field, acc ->
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

  @spec init(keyword()) :: {:ok, keyword()}
  def init(config) do
    _ = Task.start_link(fn -> create_indexes_unless_exist(nil) end)
    {:ok, config}
  end

  @spec create_indexes_unless_exist(nil | pid()) :: :ok
  def create_indexes_unless_exist(nil) do
    Logger.debug("Cluster not running yet.\n\nWaiting to create indexes...")
    Process.sleep(10_000)

    create_indexes_unless_exist(Process.whereis(__MODULE__))
  end

  def create_indexes_unless_exist(pid) when is_pid(pid) do
    existing_indices = get_existing_indices()

    # Create both indices
    _ =
      create_index_if_missing(
        existing_indices,
        Cake.Documents.ParsedDocument.index_name(),
        Cake.Documents.ParsedDocument
      )

    _ =
      create_index_if_missing(
        existing_indices,
        Cake.Books.ParsedBook.index_name(),
        Cake.Books.Chunk
      )
  end

  defp get_existing_indices() do
    case Indexes.list(__MODULE__) do
      {:ok, indices} -> indices
      {:error, error} -> raise error
    end
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

  defp ensure_index_exists(
         {:error, %Snap.HTTPClient.Error{reason: reason, origin: origin}},
         index
       ) do
    raise "Transport-layer error creating index '#{index}': Reason #{reason}, Origin: #{origin}"
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
