# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :umber,
  ecto_repos: [Umber.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :umber, Umber.Repo, migration_timestamps: [type: :utc_datetime_usec]

# Background work: the sample market's schedule, sample bidders, invoices,
# push notifications and the nightly clean-up.
config :umber, Oban,
  repo: Umber.Repo,
  queues: [default: 5, market: 5, push: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(10)}
  ]

# The sample market runs wherever the app runs, unless a config turns it off.
config :umber, :start_market, true

# Configure the endpoint
config :umber, UmberWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: UmberWeb.ErrorHTML, json: UmberWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Umber.PubSub,
  live_view: [signing_salt: "h+zu7HZc"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  umber: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  umber_css: [
    args:
      ~w(css/app.css --bundle --target=chrome111,safari16.4,firefox128 --outdir=../priv/static/assets/css --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
