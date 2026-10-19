import Config

# The database: DATABASE_URL if set (as in CI), otherwise the local server's
# socket as the current user. MIX_TEST_PARTITION allows partitioned test runs.
if url = System.get_env("DATABASE_URL") do
  config :umber, Umber.Repo, url: url
else
  config :umber, Umber.Repo, socket_dir: System.get_env("PGHOST", "/var/run/postgresql")
end

config :umber, Umber.Repo,
  database: "umber_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :umber, UmberWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NxhJhKTlJpa5p/kcmyL4/zgk2Qp97+b7KGNBX2ReHsrYe/KOhHwL1WWb7qLKaEoO",
  server: false

# Jobs run only when a test asks for them.
config :umber, Oban, testing: :manual

# The sample market and the engine's lease are started by the tests that need them.
config :umber, :start_market, false

# Fast password hashing in tests.
config :pbkdf2_elixir, :rounds, 1

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
