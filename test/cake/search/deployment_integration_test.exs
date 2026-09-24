defmodule Cake.Search.DeploymentIntegrationTest do
  @moduledoc """
  `Cake.Search.Deployment.create_collections_unless_exist/2` against a real
  node (#245): the boot path that creates every configured collection. The
  tests hand the function an explicit collection list naming the test's own
  collection, so they never touch `:search_collections` and the 10s boot
  task `init/1` spawns (which reads that config) can neither observe nor
  race them.

  `async: false`: the stand-in name module reads its name from application
  config.
  """

  use Cake.SearchIntegrationCase, async: false

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment

  defmodule BootCollection do
    @moduledoc false
    # Stand-in `name_module` for a `:search_collections` entry: the name
    # comes from config so each test can point it at its own collection.
    @spec collection_name() :: String.t()
    def collection_name, do: Application.fetch_env!(:cake, {__MODULE__, :name})
  end

  setup %{collection: collection} do
    Application.put_env(:cake, {BootCollection, :name}, collection)
    on_exit(fn -> Application.delete_env(:cake, {BootCollection, :name}) end)
    :ok
  end

  defp deployment_pid, do: Process.whereis(Deployment)

  @collections [{BootCollection, Cake.Books.Chunk}]

  describe "create_collections_unless_exist/2" do
    test "creates a listed collection that is missing, with its schema's mapping",
         %{collection: collection} do
      assert :ok = Deployment.create_collections_unless_exist(deployment_pid(), @collections)

      assert {:ok, listed} = OpenSearch.list_collections()
      assert collection in listed
      assert server_mapping!(collection)["embedding"]["type"] == "knn_vector"
    end

    test "is idempotent: a re-run leaves an existing collection alone", %{collection: collection} do
      assert :ok = Deployment.create_collections_unless_exist(deployment_pid(), @collections)
      assert :ok = Deployment.create_collections_unless_exist(deployment_pid(), @collections)

      assert {:ok, listed} = OpenSearch.list_collections()
      assert Enum.count(listed, &(&1 == collection)) == 1
    end

    test "leaves the configured :search_collections untouched" do
      before = Deployment.collections()

      assert :ok = Deployment.create_collections_unless_exist(deployment_pid(), @collections)

      assert Deployment.collections() == before
    end
  end
end
