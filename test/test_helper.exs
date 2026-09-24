# Read before ExUnit.start/1: `mix test --only integration` arrives from mix
# as include: [:integration], exclude: [:test], and ExUnit.start/1 below
# replaces the exclude list (mix merges the two back together after this
# file). A mixed run (`--include integration`) raises here, on purpose.
run_mode = Cake.SearchIntegrationCase.run_mode()

ExUnit.start(exclude: [:integration], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Two mutually exclusive run modes:
#
#   * :integration (`mix test --only integration`): repoint
#     Cake.Search.Deployment at the real cluster (OPENSEARCH_URL, `cake_test`
#     namespace) for the whole run. The Cake.SearchIntegrationCase template
#     sets :skip_search_backend to false for its tests, so the pipelines
#     really index.
#   * :unit (the default): skip search-backend operations so the pipelines
#     never touch the network; tests that need search behaviour mock the
#     backend via Mox or the HTTPClientStub adapter.
case run_mode do
  :integration -> Cake.SearchIntegrationCase.start_real_deployment!()
  :unit -> Application.put_env(:cake, :skip_search_backend, true)
end
