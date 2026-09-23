ExUnit.start(exclude: [:integration], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Two mutually exclusive run modes, decided by whether `:integration` tests
# are included (`mix test --only integration`):
#
#   * Integration run: repoint Cake.Search.Deployment at the real cluster
#     (OPENSEARCH_URL, `cake_test` namespace) for the whole run. The
#     Cake.SearchIntegrationCase template sets :skip_search_backend to false
#     for its tests, so the pipelines really index.
#   * Unit run (the default): skip search-backend operations so the
#     pipelines never touch the network; tests that need search behaviour
#     mock the backend via Mox or the HTTPClientStub adapter.
if Cake.SearchIntegrationCase.integration_run?() do
  Cake.SearchIntegrationCase.start_real_deployment!()
else
  Application.put_env(:cake, :skip_search_backend, true)
end
