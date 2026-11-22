defmodule Cake.Search.DeploymentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment
  alias Cake.Search.HTTPClientStub

  # The boot path (#363). `init/1` runs in whichever process calls the
  # cluster's `start_link/1` (Snap calls `init/1` before it starts its own
  # supervisor), so the task it links is linked to that caller: under the
  # application that is `Cake.Supervisor`, here it is the test process,
  # trapping exits as a supervisor does. The task finds the test's stub
  # responder through `$callers` (`Cake.Search.HTTPClientStub`), and the
  # responder reports every request to the test, so each test synchronizes
  # on those messages and on the task's exit signal: nothing sleeps. The
  # retry interval is injected through the `:collection_retry` key of the
  # config `init/1` receives, in milliseconds.
  @retry [initial_ms: 1, max_ms: 4]

  @docs_path "/docs"
  @chunks_path "/chunks_of_books"

  defp transport_error(reason), do: {:error, Snap.HTTPClient.Error.new(reason, :deployment_test)}

  # `GET /_cat/indices?format=json` answers with a JSON array.
  defp listing(names) do
    {:ok,
     %Snap.HTTPClient.Response{
       status: 200,
       body: Jason.encode!(Enum.map(names, &%{"index" => &1})),
       headers: [{"content-type", "application/json"}]
     }}
  end

  defp created(name) do
    HTTPClientStub.json_response(200, %{
      "acknowledged" => true,
      "shards_acknowledged" => true,
      "index" => name
    })
  end

  defp refused(status, type, reason) do
    HTTPClientStub.json_response(status, %{
      "error" => %{"type" => type, "reason" => reason},
      "status" => status
    })
  end

  # Serves the boot task's requests from `script`, a function of the request
  # and of how many requests came before it, and reports each one to the test.
  defp script_cluster(script) when is_function(script, 3) do
    test_pid = self()
    seen = :counters.new(1, [])

    HTTPClientStub.put_responder(fn method, url, _headers, _body ->
      path = URI.parse(url).path
      nth = :counters.get(seen, 1)
      :counters.add(seen, 1, 1)
      send(test_pid, {:request, method, path})
      script.(method, path, nth)
    end)
  end

  # Runs the boot path as a supervisor would and returns the task it linked.
  defp boot(config) do
    Process.flag(:trap_exit, true)
    {:links, links_before} = Process.info(self(), :links)

    assert {:ok, ^config} = Deployment.init(config)

    {:links, links_after} = Process.info(self(), :links)
    assert [task] = links_after -- links_before
    task
  end

  defp requests(acc \\ []) do
    receive do
      {:request, method, path} -> requests([{method, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The `{attempt, delay_ms}` pairs of the retry warnings that name `reason`.
  # The filter keeps out the application's own boot task, which is retrying
  # against the stub's `:no_responder` for the whole unit run.
  defp retries_logged(log, reason) do
    ~r/not reachable \(attempt (\d+)\): #{reason}; retrying collection creation in (\d+) ms/
    |> Regex.scan(log, capture: :all_but_first)
    |> Enum.map(fn [attempt, delay] -> {String.to_integer(attempt), String.to_integer(delay)} end)
  end

  describe "init/1 when the cluster answers at once" do
    test "creates what is missing without waiting, and the task exits normally" do
      script_cluster(fn
        :get, "/_cat/indices", _nth -> listing([])
        :put, @docs_path, _nth -> created("docs")
        :put, @chunks_path, _nth -> created("chunks_of_books")
      end)

      # No :collection_retry: the default interval never comes into play.
      task = boot([])

      assert_receive {:EXIT, ^task, :normal}

      assert requests() == [
               {:get, "/_cat/indices"},
               {:put, @docs_path},
               {:put, @chunks_path}
             ]
    end
  end

  describe "init/1 when the cluster is unreachable" do
    test "retries with a bounded backoff until the cluster answers, then creates only what is missing, once" do
      deployment = Process.whereis(Deployment)

      # Five transport failures, then the cluster answers: `docs` is there
      # already, `chunks_of_books` is not.
      script_cluster(fn
        :get, "/_cat/indices", nth when nth < 5 -> transport_error(:econnrefused)
        :get, "/_cat/indices", _nth -> listing(["docs"])
        :put, @chunks_path, _nth -> created("chunks_of_books")
      end)

      log =
        capture_log(fn ->
          task = boot(collection_retry: @retry)

          # A normal exit after the last request: the task lived through
          # every failure and stopped only when the work was done.
          assert_receive {:EXIT, ^task, :normal}
        end)

      assert requests() ==
               List.duplicate({:get, "/_cat/indices"}, 6) ++ [{:put, @chunks_path}]

      # Every failed attempt is logged with its reason; the delay doubles
      # from :initial_ms and stops growing at :max_ms.
      assert retries_logged(log, :econnrefused) == [{1, 1}, {2, 2}, {3, 4}, {4, 4}, {5, 4}]

      assert Process.whereis(Deployment) == deployment
      assert Process.alive?(deployment)
    end

    test "a transport failure while creating is retried too: the next pass lists again and creates only what is still missing" do
      # The node goes away between the two creates of the first pass.
      script_cluster(fn
        :get, "/_cat/indices", 0 -> listing([])
        :put, @docs_path, 1 -> created("docs")
        :put, @chunks_path, 2 -> transport_error(:closed)
        :get, "/_cat/indices", 3 -> listing(["docs"])
        :put, @chunks_path, 4 -> created("chunks_of_books")
      end)

      log =
        capture_log(fn ->
          task = boot(collection_retry: @retry)
          assert_receive {:EXIT, ^task, :normal}
        end)

      assert requests() == [
               {:get, "/_cat/indices"},
               {:put, @docs_path},
               {:put, @chunks_path},
               {:get, "/_cat/indices"},
               {:put, @chunks_path}
             ]

      assert retries_logged(log, :closed) == [{1, 1}]
    end
  end

  describe "init/1 when the cluster refuses" do
    test "a rejected mapping fails loudly: the task raises, and nothing is retried" do
      deployment = Process.whereis(Deployment)

      script_cluster(fn
        :get, "/_cat/indices", _nth ->
          listing([])

        :put, @docs_path, _nth ->
          refused(400, "mapper_parsing_exception", "unknown parameter [engine]")
      end)

      capture_log(fn ->
        task = boot(collection_retry: @retry)

        assert_receive {:EXIT, ^task, {%RuntimeError{message: message}, _stacktrace}}
        assert message =~ "Application error creating collection 'docs'"
        assert message =~ "Status 400"
      end)

      # The pass stops at the refusal: one list, one create, no second try.
      assert requests() == [{:get, "/_cat/indices"}, {:put, @docs_path}]

      assert Process.whereis(Deployment) == deployment
      assert Process.alive?(deployment)
    end

    test "a rejected list fails loudly too: the task raises, and nothing is retried" do
      script_cluster(fn :get, "/_cat/indices", _nth ->
        refused(403, "security_exception", "no permissions for [indices:monitor/stats]")
      end)

      capture_log(fn ->
        task = boot(collection_retry: @retry)

        assert_receive {:EXIT, ^task, {%RuntimeError{message: message}, _stacktrace}}
        assert message =~ "Application error listing collections"
        assert message =~ "Status 403"
      end)

      assert requests() == [{:get, "/_cat/indices"}]
    end
  end

  describe "create_collections_unless_exist/2 (one pass, no retry)" do
    test "raises on a transport error, naming the reason, after its one request" do
      script_cluster(fn :get, "/_cat/indices", _nth -> transport_error(:econnrefused) end)

      assert_raise RuntimeError,
                   ~r/Transport-layer error listing collections.*econnrefused/s,
                   fn ->
                     Deployment.create_collections_unless_exist(
                       Process.whereis(Deployment),
                       Deployment.collections()
                     )
                   end

      assert requests() == [{:get, "/_cat/indices"}]
    end
  end

  describe "collections/0" do
    test "reads the collection list from :search_collections config" do
      # Each entry is {name_module, mapping_schema}: the first supplies the
      # collection name via collection_name/0, the second the index mapping.
      collections = Deployment.collections()

      assert {Cake.Documents.ParsedDocument, Cake.Documents.ParsedDocument} in collections
      assert {Cake.Books.ParsedBook, Cake.Books.Chunk} in collections
    end

    test "is overridable via application config" do
      original = Application.get_env(:cake, :search_collections)
      override = [{Cake.Books.ParsedBook, Cake.Books.Chunk}]
      Application.put_env(:cake, :search_collections, override)
      on_exit(fn -> Application.put_env(:cake, :search_collections, original) end)

      assert Deployment.collections() == override
    end
  end

  describe "build_mapping/1" do
    test "maps :text fields to OpenSearch text type" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      props = mapping.mappings.properties

      assert props.text == %{type: "text"}
    end

    test "maps :embedding field to knn_vector with HNSW config" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      embedding = mapping.mappings.properties.embedding

      assert embedding.type == "knn_vector"
      assert embedding.dimension == 1536
      assert embedding.method.name == "hnsw"
      assert embedding.method.space_type == "cosinesimil"
      assert embedding.method.engine == "faiss"
    end

    test "reads vector dimension from application config" do
      Application.put_env(:cake, :default_embedding_dimension, 3072)
      on_exit(fn -> Application.delete_env(:cake, :default_embedding_dimension) end)

      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      embedding = mapping.mappings.properties.embedding

      assert embedding.dimension == 3072
    end

    test "maps non-text, non-embedding fields as keyword" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      props = mapping.mappings.properties

      assert props.source == %{type: "keyword"}
      assert props.version == %{type: "keyword"}
      assert props.package == %{type: "keyword"}
    end

    test "includes knn settings" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)

      assert mapping.settings["index.knn"] == true
    end

    test "works with Chunk schema" do
      mapping = OpenSearch.build_mapping(Cake.Books.Chunk)
      props = mapping.mappings.properties

      assert props.text == %{type: "text"}
      assert props.embedding.type == "knn_vector"
      assert props[:chunk_index] == %{type: "keyword"}
    end
  end
end
