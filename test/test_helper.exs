# Read before ExUnit.start/1: `mix test --only integration` arrives from mix
# as include: [:integration], exclude: [:test], and ExUnit.start/1 below
# replaces the exclude list (mix merges the two back together after this
# file). A mixed run (`--include integration`) raises here, on purpose.
run_mode = Cake.SearchIntegrationCase.run_mode()

# Two opt-in tags, both excluded by default (CLAUDE.md "Live LLM tests"):
# :integration is hermetic infrastructure (OpenSearch, NIF, Oban), run by
# `mix test --only integration`; :llm is real provider calls — secret- and
# cost-bearing — run by `mix test --only llm` with OPENAI_KEY set.
ExUnit.start(exclude: [:integration, :llm], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Search-backend operations are skipped in every run mode: the pipelines
# never touch the network unless a test opted in. Only Cake.SearchIntegrationCase
# turns the flag off, in its own setup, for the tests that use it; every other
# test — including pre-existing :integration-tagged ones such as the Oban job
# tests — keeps skipping. Tests that need search behaviour mock the backend
# via Mox or the HTTPClientStub adapter.
Application.put_env(:cake, :skip_search_backend, true)

# An integration run (`mix test --only integration`) additionally repoints
# Cake.Search.Deployment at the real cluster (OPENSEARCH_URL, `cake_test`
# namespace) for the whole run, so the tests that opt in really index.
if run_mode == :integration do
  Cake.SearchIntegrationCase.start_real_deployment!()
end
