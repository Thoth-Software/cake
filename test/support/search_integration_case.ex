defmodule Cake.SearchIntegrationCase do
  @moduledoc """
  Case template for tests that talk to a real search cluster (#245).

  `use Cake.SearchIntegrationCase, async: true` tags the module's tests
  `:integration`, sets up the Ecto sandbox (the round-trip tests hydrate
  hits from Postgres), neutralizes the `:skip_search_backend` flag for the
  run, and hands each test a `:collection` name unique to it. Everything a
  test creates under that name is dropped again in `on_exit`.

  ## How the cluster is reached

  `config/test.exs` wires `Cake.Search.Deployment` to the
  `Cake.Search.HTTPClientStub` adapter so unit tests never touch the
  network. An integration run (`mix test --only integration`) needs the
  opposite, so `test/test_helper.exs` calls `start_real_deployment!/0`,
  which repoints the Deployment's config at `OPENSEARCH_URL` (default
  `http://localhost:9200`) and restarts it under `Cake.Supervisor`. The
  config sets Snap's `index_namespace` to `"cake_test"`, so every
  collection the convenience API creates, lists, searches or deletes is
  really `cake_test-<name>` on the server: a developer's `docs` and
  `chunks_of_books` indices are out of reach, and `Snap.Indexes.list/1`
  (and so `Backend.OpenSearch.list_collections/0`) only ever reports the
  namespace.

  Unit and integration tests cannot share one run: the skip flag and the
  Deployment config are global. That is why CI runs the integration job as
  its own `--only integration` invocation.

  ## Flake hazards this template absorbs

    * The production mapping sets `index.refresh_interval` to 30s, so
      nothing indexed is searchable until `refresh!/1` is called.
    * `Cake.Search.Deployment.init/1` spawns a task that sleeps 10s and then
      creates the configured collections. Tests never wait on it: they
      create what they need themselves, under names of their own. (The
      restart in `start_real_deployment!/0` spawns a second such task; both
      land in the namespace and neither is a test's concern.)
    * Collection names are random per test, so async tests never see each
      other's indices, and a crashed run leaves nothing a later run can
      collide with.
  """

  use ExUnit.CaseTemplate

  alias Cake.Search.Deployment

  @namespace "cake_test"
  @default_url "http://localhost:9200"
  @readiness_attempts 60
  @readiness_interval_ms 1_000

  using do
    quote do
      @moduletag :integration

      import Cake.SearchIntegrationCase
    end
  end

  setup tags do
    Cake.DataCase.setup_sandbox(tags)
    assert_real_deployment!()
    Application.put_env(:cake, :skip_search_backend, false)

    collection = new_collection_prefix()
    on_exit(fn -> drop_collections!(collection) end)

    %{collection: collection}
  end

  @doc """
  Whether this ExUnit run includes `:integration`-tagged tests, i.e. was
  started with `--only integration` or `--include integration`. Read by
  `test/test_helper.exs` before it decides how to configure the search
  backend.
  """
  @spec integration_run?() :: boolean()
  def integration_run? do
    :integration in Keyword.get(ExUnit.configuration(), :include, [])
  end

  @doc "The cluster URL: `OPENSEARCH_URL`, or `#{@default_url}`."
  @spec opensearch_url() :: String.t()
  def opensearch_url, do: System.get_env("OPENSEARCH_URL", @default_url)

  @doc "The Snap index namespace every integration collection lives under."
  @spec index_namespace() :: String.t()
  def index_namespace, do: @namespace

  @doc """
  Repoints `Cake.Search.Deployment` at the real cluster for the rest of
  this run: replaces its application config (URL, `cake_test` namespace,
  Snap's default Finch adapter instead of the test stub), restarts it under
  `Cake.Supervisor`, and waits until the node answers. Raises with the URL
  and the local start-up command if it never does.
  """
  @spec start_real_deployment!() :: :ok
  def start_real_deployment! do
    Application.put_env(:cake, Deployment, url: opensearch_url(), index_namespace: @namespace)

    :ok = Supervisor.terminate_child(Cake.Supervisor, Deployment)
    {:ok, _pid} = Supervisor.restart_child(Cake.Supervisor, Deployment)

    await_cluster!(@readiness_attempts)
  end

  @doc """
  Derives a further collection name unique to the calling test, under the
  same prefix as its `:collection`, so the template's teardown drops it too.
  """
  @spec unique_collection_name(map()) :: String.t()
  def unique_collection_name(%{collection: prefix}) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  @doc """
  Refreshes `collection` so every document indexed so far is searchable.
  Raises if the cluster refuses (e.g. the collection does not exist).
  """
  @spec refresh!(String.t()) :: :ok
  def refresh!(collection) when is_binary(collection) do
    case Snap.Indexes.refresh(Deployment, collection) do
      :ok -> :ok
      {:error, error} -> raise "refresh of #{collection} failed: #{inspect(error)}"
    end
  end

  @doc """
  Drops every collection in the namespace whose name starts with `prefix`.
  A prefix with nothing under it is a no-op. Raises on any cluster error.
  """
  @spec drop_collections!(String.t()) :: :ok
  def drop_collections!(prefix) when is_binary(prefix) do
    {:ok, existing} = Snap.Indexes.list(Deployment)

    existing
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.each(fn name -> {:ok, _} = Snap.Indexes.delete(Deployment, name) end)
  end

  defp new_collection_prefix do
    "it_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp assert_real_deployment! do
    unless Keyword.get(Deployment.config(), :index_namespace) == @namespace do
      raise """
      Cake.SearchIntegrationCase tests need the real cluster, but \
      Cake.Search.Deployment still carries the unit-test config. Run them \
      with `mix test --only integration` (see CLAUDE.md, "Integration tests").\
      """
    end
  end

  # Readiness probe, run once per integration run from test_helper.exs
  # (never from a test): a node started moments ago by `docker compose up`
  # takes a while to answer, and CI's health check already guarantees it.
  defp await_cluster!(attempts_left) do
    case Deployment.get("/") do
      {:ok, %{"version" => _}} ->
        :ok

      {:error, _error} when attempts_left > 1 ->
        Process.sleep(@readiness_interval_ms)
        await_cluster!(attempts_left - 1)

      {:error, error} ->
        raise """
        No OpenSearch at #{opensearch_url()} after #{@readiness_attempts} attempts: \
        #{inspect(error)}

        Start one with `docker compose up -d opensearch`, or point OPENSEARCH_URL \
        at a running node.\
        """
    end
  end
end
