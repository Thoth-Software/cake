ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Caque.Repo, :manual)

# Skip OpenSearch operations in tests to avoid connection errors
Application.put_env(:caque, :skip_opensearch, true)
