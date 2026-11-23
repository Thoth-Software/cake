defmodule Cake.Search.Deployment do
  @moduledoc """
  Search deployment process — the Snap cluster that connects to OpenSearch.

  Manages lifecycle: starts the connection and creates the collections that
  do not exist yet (`create_missing_collections/1`). It does not decide when:
  at boot that is `Cake.Search.CollectionSetup`, the next child in the
  supervision tree, which retries until the cluster answers. Named
  `Deployment` because it represents the running search engine instance,
  regardless of backend (OpenSearch cluster, Qdrant instance, etc.).
  """

  use Snap.Cluster, otp_app: :cake

  alias Cake.Search.Backend
  alias Cake.Search.Backend.OpenSearch

  require Logger

  @doc """
  Creates every collection in `collections` that the deployment does not
  have yet, leaving existing ones untouched: one pass, no retry. Each entry
  is `{name_module, mapping_schema}` as in `collections/0`.

  A pass has two ways to fail, and they are reported differently on purpose:

    * the cluster is **not reachable yet** (a transport failure, or a 5xx
      from the node or from a proxy in front of it): the pass stops and
      returns `{:error, {step, error}}`, `step` naming what it was doing
      (`"listing collections"`, `"creating collection 'docs'"`). Running
      the pass again later is safe: it lists again and creates only what is
      still missing.
    * the cluster **refuses** the request (any other response, such as a
      rejected mapping): the pass raises. Trying again would get the same
      answer.
  """
  @spec create_missing_collections([{module(), module()}]) ::
          :ok | {:error, {String.t(), Backend.search_error()}}
  def create_missing_collections(collections) when is_list(collections) do
    case OpenSearch.list_collections() do
      {:ok, existing} ->
        Enum.reduce_while(collections, :ok, fn {name_module, mapping_schema}, :ok ->
          name = name_module.collection_name()

          case create_collection_if_missing(existing, name, mapping_schema) do
            :ok -> {:cont, :ok}
            {:error, _unreachable} = error -> {:halt, error}
          end
        end)

      {:error, error} ->
        unreachable_or_raise(error, "listing collections")
    end
  end

  @doc """
  `create_missing_collections/1` for a caller that wants one pass or a
  crash: raises when the cluster cannot be reached as well as when it
  refuses. Callers with their own list (integration tests, for one) pass it
  here and never touch the `:search_collections` config.
  """
  @spec create_collections_unless_exist(pid(), [{module(), module()}]) :: :ok
  def create_collections_unless_exist(pid, collections)
      when is_pid(pid) and is_list(collections) do
    case create_missing_collections(collections) do
      :ok -> :ok
      {:error, {step, error}} -> raise "Transport-layer error #{step}: #{describe_error(error)}"
    end
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

  defp create_collection_if_missing(existing, name, schema) do
    if name in existing do
      Logger.info("Collection '#{name}' already exists")
    else
      Logger.info("Creating collection '#{name}'...")

      case OpenSearch.create_collection(name, OpenSearch.build_mapping(schema)) do
        :ok -> Logger.info("Successfully created collection '#{name}'")
        {:error, error} -> unreachable_or_raise(error, "creating collection '#{name}'")
      end
    end
  end

  defp unreachable_or_raise(%Snap.HTTPClient.Error{} = error, step), do: {:error, {step, error}}

  defp unreachable_or_raise(%{status: status} = error, step)
       when is_integer(status) and status >= 500,
       do: {:error, {step, error}}

  defp unreachable_or_raise(%Snap.ResponseError{status: status, message: message}, step) do
    raise "Application error #{step}: Status #{status}, Message: #{message}"
  end

  # A response Snap could not read as JSON: a `Jason.DecodeError` for a 2xx
  # body, a `Snap.HTTPError` for any other status. (No clause names
  # `Snap.HTTPError`: Snap's specs leave it out of the errors it returns, so
  # dialyzer would call the clause unreachable.)
  defp unreachable_or_raise(error, step) do
    raise "Application layer error #{step} (cannot parse JSON): #{Exception.message(error)}"
  end

  defp describe_error(%Snap.HTTPClient.Error{reason: reason, origin: origin}) do
    "Reason #{reason}, Origin: #{inspect(origin)}"
  end

  defp describe_error(error), do: Exception.message(error)
end
