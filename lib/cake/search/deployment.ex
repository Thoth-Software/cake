defmodule Cake.Search.Deployment do
  @moduledoc """
  Search deployment process — the Snap cluster that connects to OpenSearch.

  Manages lifecycle: starts the connection, and owns the boot-time creation
  of the configured collections (`create_configured_collections/0`), which
  Cake.Application runs in a one-shot task right after this cluster starts.
  Named `Deployment` because it represents the running search engine
  instance, regardless of backend (OpenSearch cluster, Qdrant instance,
  etc.).
  """

  use Snap.Cluster, otp_app: :cake

  alias Cake.Search.Backend

  require Logger

  @doc """
  Boot-time collection creation: one `create_collections_unless_exist/2`
  pass over the `collections/0` list against the running cluster process.
  Cake.Application runs it in a one-shot `Task` child started right after
  this cluster, and children start in order, so the cluster is registered by
  the time it runs; no polling. Skipped, with a debug log, when
  `config :cake, :skip_search_backend` is set — the flag that keeps
  `Cake.Pipelines.add_to_search_backend/3` off the network, which the test
  env sets at boot.
  """
  @spec create_configured_collections() :: :ok
  def create_configured_collections do
    if Application.get_env(:cake, :skip_search_backend, false) do
      Logger.debug("Skipping boot-time collection creation (:skip_search_backend is set)")
      :ok
    else
      create_collections_unless_exist(Process.whereis(__MODULE__), collections())
    end
  end

  @doc """
  Creates every collection in `collections` that the deployment does not
  have yet, leaving existing ones untouched, through the configured
  `Cake.Search.Backend` (`Backend.backend/0`): its `list_collections/0`,
  then `build_mapping/1` and `create_collection/2` for each missing one.
  Each entry is `{name_module, mapping_schema}` as in `collections/0`, which
  is what the boot path passes; callers with their own list (integration
  tests, for one) pass it here and never touch the `:search_collections`
  config. `pid` is the running cluster process: the caller shows the
  deployment is up before asking it for collections.
  """
  @spec create_collections_unless_exist(pid(), [{module(), module()}]) :: :ok
  def create_collections_unless_exist(pid, collections)
      when is_pid(pid) and is_list(collections) do
    backend = Backend.backend()
    {:ok, existing} = backend.list_collections()

    Enum.each(collections, fn {name_module, mapping_schema} ->
      create_collection_if_missing(
        backend,
        existing,
        name_module.collection_name(),
        mapping_schema
      )
    end)
  end

  @doc """
  The collections to ensure at boot, read from `:search_collections` config.

  Each entry is `{name_module, mapping_schema}`: `name_module.collection_name/0`
  supplies the collection name and `mapping_schema` supplies the index mapping.
  Keeping this list in config (rather than naming the GDS modules here) keeps
  the search layer from depending on the ingestion contexts.
  """
  @spec collections() :: [{module(), module()}]
  def collections do
    Application.get_env(:cake, :search_collections, [])
  end

  defp create_collection_if_missing(backend, existing, name, schema) do
    if name in existing do
      Logger.info("Collection '#{name}' already exists")
      {:ok, "Collection already exists"}
    else
      Logger.info("Creating collection '#{name}'...")
      mapping = backend.build_mapping(schema)
      result = backend.create_collection(name, mapping)
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
