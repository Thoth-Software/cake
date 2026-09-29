# Read before ExUnit.start/1: `mix test --only integration` arrives from mix
# as include: [:integration], exclude: [:test], and ExUnit.start/1 below
# replaces the exclude list (mix merges the two back together after this
# file). A mixed run (`--include integration`) raises here, on purpose.
run_mode = Cake.SearchIntegrationCase.run_mode()

# Three opt-in tags, all excluded by default (CLAUDE.md "Live LLM tests"):
# :integration is hermetic infrastructure (OpenSearch, NIF, Oban), run by
# `mix test --only integration`; :llm is real provider calls — secret- and
# cost-bearing — run by `mix test --only llm` with OPENAI_KEY set; :network
# is the integration tests that also reach the public internet (the hexdocs
# pipeline's `git clone` of elixir-lang/elixir), tagged :network *instead
# of* :integration (`use Cake.SearchIntegrationCase, network: true`) because
# an include wins over an exclude and a test carrying both tags could never
# be opted out of. They run only with
# `mix test --only integration --include network`, which the merge gate
# passes; `--only integration` alone leaves them out.
ExUnit.start(exclude: [:integration, :llm, :network], assert_receive_timeout: 1_000)
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
