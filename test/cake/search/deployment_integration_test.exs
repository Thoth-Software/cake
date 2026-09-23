defmodule Cake.Search.DeploymentIntegrationTest do
  @moduledoc """
  `Cake.Search.Deployment.create_collections_unless_exist/1` against a real
  node (#245): the boot path that creates every configured collection. The
  tests never wait on the 10s boot task `init/1` spawns; they call the
  function directly, with `:search_collections` pointed at a collection
  named for the test, so nothing collides with the task's own run or with
  other tests.

  `async: false`: `:search_collections` is application config.
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

  describe "create_collections_unless_exist/1" do
    test "creates a configured collection that is missing, with its schema's mapping",
         %{collection: collection} do
      with_search_collections([{BootCollection, Cake.Books.Chunk}], fn ->
        assert :ok = Deployment.create_collections_unless_exist(deployment_pid())
      end)

      assert {:ok, listed} = OpenSearch.list_collections()
      assert collection in listed
      assert server_mapping!(collection)["embedding"]["type"] == "knn_vector"
    end

    test "is idempotent: a re-run leaves an existing collection alone", %{collection: collection} do
      with_search_collections([{BootCollection, Cake.Books.Chunk}], fn ->
        assert :ok = Deployment.create_collections_unless_exist(deployment_pid())
        assert :ok = Deployment.create_collections_unless_exist(deployment_pid())
      end)

      assert {:ok, listed} = OpenSearch.list_collections()
      assert Enum.count(listed, &(&1 == collection)) == 1
    end

    test "restores the :search_collections config afterwards" do
      original = Deployment.collections()

      with_search_collections([{BootCollection, Cake.Books.Chunk}], fn ->
        assert Deployment.collections() == [{BootCollection, Cake.Books.Chunk}]
      end)

      assert Deployment.collections() == original
    end
  end
end
