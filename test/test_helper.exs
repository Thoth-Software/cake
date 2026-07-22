ExUnit.start(exclude: [:integration], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Cake.Repo, :manual)

# Skip search backend operations in tests to avoid connection errors
Application.put_env(:cake, :skip_search_backend, true)
