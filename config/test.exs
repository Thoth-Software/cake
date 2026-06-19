import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cake, Cake.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cake_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cake, CakeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "oxyJQXHV63h00hZ9XkLVIO5RZRW6Ut46lh5a9qw1pfErmP7ZMBweaMPbNxbxHNzk",
  server: false

# In test we don't send emails
config :cake, Cake.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# config/test.exs
config :cake, Oban, testing: :manual

config :cake, Cake.Generation.OpenAI,
  openai_key: "test-key-not-real",
  response_url: "http://localhost/v1/responses",
  plug: {Req.Test, Cake.Generation.OpenAI}

config :cake, Cake.Embeddings,
  openai_key: "test-key-not-real",
  base_url: "http://localhost/v1/embeddings",
  plug: {Req.Test, Cake.Embeddings}
