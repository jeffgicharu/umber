import Config

# The database: DATABASE_URL if set, otherwise the local server's socket as the
# current user.
if url = System.get_env("DATABASE_URL") do
  config :umber, Umber.Repo, url: url
else
  config :umber, Umber.Repo,
    socket_dir: System.get_env("PGHOST", "/var/run/postgresql"),
    database: "umber_dev"
end

config :umber, Umber.Repo,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable debugging and code reloading.
config :umber, UmberWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  # Development only. Production reads SECRET_KEY_BASE from the environment.
  secret_key_base: "8WA8XV0kOwL6Z7ujSOQy2XpG8w2x8fVgx/N7Up64WqvEr3BTK0Mc4cRVJ0t02v5n",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:umber, ~w(--sourcemap=inline --watch)]},
    esbuild_css: {Esbuild, :install_and_run, [:umber_css, ~w(--sourcemap=inline --watch)]}
  ]

# Enable dev routes for the dashboard
config :umber, dev_routes: true

# The guest staff link for trying the desk locally: /desk/try?key=local-desk
config :umber, :staff_trial_key, "local-desk"

# Do not include metadata nor timestamps in development logs, and leave out
# every query: the market runs a few each second.
config :logger, :default_formatter, format: "[$level] $message\n"
config :logger, level: :info

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
