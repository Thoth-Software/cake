ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Skip search backend operations in tests to avoid connection errors
Application.put_env(:cake, :skip_search_backend, true)
