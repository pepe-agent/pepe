import Config

# No Repo config block here on purpose: Pepe.Repo is never auto-started under
# `Application.start/2` in :test (see application.ex) - each test that touches it
# starts its own instance, pointed at that test's own PEPE_HOME, via Pepe.RepoSetup.

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
