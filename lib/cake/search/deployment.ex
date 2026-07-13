defmodule Cake.Search.Deployment do
  @moduledoc """
  Search deployment process — the Snap cluster that connects to OpenSearch.

  Manages lifecycle: starts the connection, creates collections on init
  if they don't exist. Named `Deployment` because it represents the running
  search engine instance, regardless of backend (OpenSearch cluster,
  Qdrant instance, etc.).
  """

  use Snap.Cluster, otp_app: :cake

  alias Cake.Search.Backends.OpenSearch

  require Logger

  @spec init(keyword()) :: {:ok, keyword()}
  def init(config) do
    _ = Task.start_link(fn -> create_collections_unless_exist(nil) end)
    {:ok, config}
  end

  @spec create_collections_unless_exist(nil | pid()) :: :ok
  def create_collections_unless_exist(nil) do
    Logger.debug("Deployment not running yet.\n\nWaiting to create collections...")
    Process.sleep(10_000)

    create_collections_unless_exist(Process.whereis(__MODULE__))
  end

  def create_collections_unless_exist(pid) when is_pid(pid) do
    {:ok, existing} = OpenSearch.list_collections()

    _ =
      create_collection_if_missing(
        existing,
        Cake.Documents.ParsedDocument.collection_name(),
        Cake.Documents.ParsedDocument
      )

    _ =
      create_collection_if_missing(
        existing,
        Cake.Books.ParsedBook.collection_name(),
        Cake.Books.Chunk
      )
  end

  defp create_collection_if_missing(existing, name, schema) do
    if name in existing do
      Logger.info("Collection '#{name}' already exists")
      {:ok, "Collection already exists"}
    else
      Logger.info("Creating collection '#{name}'...")
      mapping = OpenSearch.build_mapping(schema)
      result = OpenSearch.create_collection(name, mapping)
      handle_create_result(result, name)
    end
  end

  defp handle_create_result(:ok, name) do
    Logger.info("Successfully created collection '#{name}'")
    :ok
  end

  defp handle_create_result(
         {:error, %Snap.HTTPClient.Error{reason: reason, origin: origin}},
         name
       ) do
    raise "Transport-layer error creating collection '#{name}': Reason #{reason}, Origin: #{origin}"
  end

  defp handle_create_result({:error, %Snap.ResponseError{status: status, message: message}}, name) do
    raise "Application error creating collection '#{name}': Status #{status}, Message: #{message}"
  end

  defp handle_create_result({:error, %Jason.DecodeError{data: data}}, name) do
    raise "Application layer error creating collection '#{name}' (cannot parse JSON):\n\n Data: #{data}"
  end

  defp handle_create_result(_, _name), do: :ok
end
