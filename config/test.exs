import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pepe, Pepe.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pepe_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pepe, PepeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wv4Gwv4ze6r8+JmDuAAyC6KEBvJR2a1iJ3BNkvSTB31Dkc2lfyu6jPHRcxx5aUkv",
  server: false

# In test we don't send emails
config :pepe, Pepe.Mailer, adapter: Swoosh.Adapters.Test

# A low login rate-limit so the throttle test hits its ceiling quickly.
config :pepe, login_max_attempts: 3

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
