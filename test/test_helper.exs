ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Skip OpenSearch operations in tests to avoid connection errors
Application.put_env(:cake, :skip_opensearch, true)

# Initialize the Generation stub's shared ETS table once per suite.
Cake.Test.GenerationStub.setup_table()
