defmodule Cake.Search.CollectionSetupTest do
  @moduledoc """
  The boot-time collection creation child (#363), over
  `Cake.Search.HTTPClientStub`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cake.Search.CollectionSetup
  alias Cake.Search.Deployment
  alias Cake.Search.HTTPClientStub

  # Each test starts the child itself, linked to the test process (trapping
  # exits as a supervisor does) rather than under a supervisor: the task then
  # finds the test's stub responder through `$callers`
  # (`Cake.Search.HTTPClientStub`). The responder reports every request to
  # the test, so a test synchronizes on those messages and on the task's
  # exit signal: nothing sleeps. The retry interval is injected through the
  # child's `:initial_ms` and `:max_ms` options.
  @retry [initial_ms: 1, max_ms: 4]

  @docs_path "/docs"
  @chunks_path "/chunks_of_books"

  defp transport_error(reason),
    do: {:error, Snap.HTTPClient.Error.new(reason, :collection_setup_test)}

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

  # What a proxy sends when the node behind it is down: no JSON.
  defp bad_gateway do
    {:ok,
     %Snap.HTTPClient.Response{
       status: 502,
       body: "<html><body>502 Bad Gateway</body></html>",
       headers: [{"content-type", "text/html"}]
     }}
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

  # Starts the child as a supervisor would and returns the task.
  defp boot(opts) do
    Process.flag(:trap_exit, true)
    assert {:ok, task} = CollectionSetup.start_link(opts)
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
  # The filter keeps out the application's own child, whose one attempt
  # against the stub's `:no_responder` is logged in every unit run.
  defp retries_logged(log, reason) do
    ~r/not reachable \(attempt (\d+)\): #{reason}[^\n]*?; retrying collection creation in (\d+) ms/
    |> Regex.scan(log, capture: :all_but_first)
    |> Enum.map(fn [attempt, delay] -> {String.to_integer(attempt), String.to_integer(delay)} end)
  end

  describe "when the cluster answers at once" do
    test "creates what is missing without waiting, and the task exits normally" do
      script_cluster(fn
        :get, "/_cat/indices", _nth -> listing([])
        :put, @docs_path, _nth -> created("docs")
        :put, @chunks_path, _nth -> created("chunks_of_books")
      end)

      # No retry options: the default interval never comes into play.
      task = boot([])

      assert_receive {:EXIT, ^task, :normal}

      assert requests() == [
               {:get, "/_cat/indices"},
               {:put, @docs_path},
               {:put, @chunks_path}
             ]
    end
  end

  describe "when the cluster is unreachable" do
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
          task = boot(@retry)

          # A normal exit after the last request: the task lived through
          # every failure and stopped only when the work was done.
          assert_receive {:EXIT, ^task, :normal}
        end)

      # Six lists (five refused connections, one answer), then the one create.
      assert {lists, [{:put, @chunks_path}]} = Enum.split(requests(), 6)
      assert lists == List.duplicate({:get, "/_cat/indices"}, 6)

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
          task = boot(@retry)
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

    test "a 5xx is not reachable yet either: retried, whether or not the body is JSON" do
      # A proxy answering for a node that is down, then the node still
      # starting, then the node.
      script_cluster(fn
        :get, "/_cat/indices", 0 -> bad_gateway()
        :get, "/_cat/indices", 1 -> refused(503, "cluster_block_exception", "not recovered")
        :get, "/_cat/indices", _nth -> listing(["docs", "chunks_of_books"])
      end)

      log =
        capture_log(fn ->
          task = boot(@retry)
          assert_receive {:EXIT, ^task, :normal}
        end)

      # Nothing was missing, so nothing is created.
      assert requests() == List.duplicate({:get, "/_cat/indices"}, 3)

      assert retries_logged(log, "HTTP status 502") == [{1, 1}]
      assert retries_logged(log, "HTTP status 503") == [{2, 2}]
      assert log =~ "cluster_block_exception"
    end
  end

  describe "when the cluster refuses" do
    test "a rejected mapping fails loudly: the task raises, and nothing is retried" do
      deployment = Process.whereis(Deployment)

      script_cluster(fn
        :get, "/_cat/indices", _nth ->
          listing([])

        :put, @docs_path, _nth ->
          refused(400, "mapper_parsing_exception", "unknown parameter [engine]")
      end)

      capture_log(fn ->
        task = boot(@retry)

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
        task = boot(@retry)

        assert_receive {:EXIT, ^task, {%RuntimeError{message: message}, _stacktrace}}
        assert message =~ "Application error listing collections"
        assert message =~ "Status 403"
      end)

      assert requests() == [{:get, "/_cat/indices"}]
    end
  end

  describe "under the application" do
    test "is a temporary child of Cake.Supervisor, started right after the Deployment" do
      # which_children/1 lists the newest child first.
      ids =
        Cake.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
        |> Enum.reverse()

      assert [Deployment, CollectionSetup] ==
               Enum.filter(ids, &(&1 in [Deployment, CollectionSetup]))

      deployment_index = Enum.find_index(ids, &(&1 == Deployment))
      assert Enum.at(ids, deployment_index + 1) == CollectionSetup

      # Temporary: a refusal is reported once and never takes the application
      # down through the supervisor's restart limit.
      assert %{restart: :temporary} = CollectionSetup.child_spec([])
    end
  end
end
