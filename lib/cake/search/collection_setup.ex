defmodule Cake.Search.CollectionSetup do
  @moduledoc """
  Boot-time collection creation: the child of the application's supervision
  tree that makes sure every collection in `:search_collections` exists
  (#363).

  It starts right after `Cake.Search.Deployment`, so the cluster process is
  registered by the time it runs, and it does one thing: run
  `Cake.Search.Deployment.create_missing_collections/1` until a pass
  completes, then exit. A pass that finds the cluster not reachable yet (a
  transport failure or a 5xx) is logged as a warning with its reason and
  retried after a delay that doubles from `:initial_ms` up to `:max_ms`,
  for as long as it takes: the search node may come up minutes after the
  application, and nothing else would create the collections when it does.
  Meanwhile the application serves, and a search returns the backend's
  `{:error, _}` tuple.

  A pass the cluster refuses (a rejected mapping, say) raises. The child is
  `:temporary`, so that is reported once, as a crashed task, and the
  application stays up without the collection: a restart would be refused
  the same way, and five of those would take the whole tree down.

  ## Options

  `start_link/1` reads each of these from its argument, then from
  `config :cake, Cake.Search.CollectionSetup`, then from the default:

    * `:initial_ms` - the delay after the first failed pass (default 1000)
    * `:max_ms` - the bound the doubling delay stops at (default 30 000)
    * `:collections` - the `{name_module, mapping_schema}` pairs to ensure
      (default `Cake.Search.Deployment.collections/0`)
  """

  use Task, restart: :temporary

  alias Cake.Search.Deployment

  require Logger

  @defaults [initial_ms: 1_000, max_ms: 30_000]

  @typedoc "Options of `start_link/1`; see the module documentation."
  @type option ::
          {:initial_ms, pos_integer()}
          | {:max_ms, pos_integer()}
          | {:collections, [{module(), module()}]}

  @doc "Starts the task, linked to the caller. See the module documentation for `opts`."
  @spec start_link([option()]) :: {:ok, pid()}
  def start_link(opts) when is_list(opts) do
    opts =
      @defaults
      |> Keyword.merge(Application.get_env(:cake, __MODULE__, []))
      |> Keyword.merge(opts)
      |> Keyword.put_new_lazy(:collections, &Deployment.collections/0)

    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc """
  The task's body: passes over `:collections` until one completes, waiting
  between failed ones. Returns `:ok` once every collection exists; raises
  when the cluster refuses a request.
  """
  @spec run([option()]) :: :ok
  def run(opts) when is_list(opts) do
    max_ms = Keyword.fetch!(opts, :max_ms)
    initial_ms = min(Keyword.fetch!(opts, :initial_ms), max_ms)

    retry_until_reachable(Keyword.fetch!(opts, :collections), 1, initial_ms, max_ms)
  end

  defp retry_until_reachable(collections, attempt, delay_ms, max_ms) do
    case Deployment.create_missing_collections(collections) do
      :ok ->
        :ok

      {:error, {step, error}} ->
        Logger.warning(
          "Search cluster at #{cluster_address()} not reachable (attempt #{attempt}): " <>
            "#{reason(error)} while #{step}; retrying collection creation in #{delay_ms} ms"
        )

        Process.sleep(delay_ms)
        retry_until_reachable(collections, attempt + 1, min(delay_ms * 2, max_ms), max_ms)
    end
  end

  defp reason(%{status: status} = error) when is_integer(status) do
    case Exception.message(error) do
      "HTTP status " <> _rest = message -> message
      message -> "HTTP status #{status} #{message}"
    end
  end

  defp reason(error), do: Exception.message(error)

  # Scheme, host and port only: the configured URL may carry credentials.
  defp cluster_address do
    uri = URI.parse(Keyword.fetch!(Deployment.config(), :url))
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end
end
