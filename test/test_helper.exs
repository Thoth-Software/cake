ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Skip OpenSearch operations in tests to avoid connection errors
Application.put_env(:cake, :skip_opensearch, true)
