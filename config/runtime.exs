import Config

# config/runtime.exs is executed for all environments, including during
# releases, after compilation and before the system starts.

if System.get_env("PHX_SERVER") do
  config :umber, UmberWeb.Endpoint, server: true
end

config :umber, UmberWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :umber, UmberWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg|webp|avif)$"E,
        ~r"lib/umber_web/router\.ex$"E,
        ~r"lib/umber_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The commit a release was built from, written beside it as REVISION.
  release_revision = fn ->
    path = Path.join([System.get_env("RELEASE_ROOT", "."), "REVISION"])
    if File.exists?(path), do: path |> File.read!() |> String.trim(), else: "unknown"
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing"

  config :umber, Umber.Repo,
    url: database_url,
    # Two release slots run side by side during a switch, each with its own
    # pool, within the role's connection limit of 20.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "8")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  host = System.get_env("PHX_HOST") || "umber.jeffgicharu.com"

  config :umber, UmberWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Local connections only; nginx is the only way in from outside.
    http: [ip: {127, 0, 0, 1}],
    check_origin: ["https://#{host}"],
    secret_key_base: secret_key_base

  config :umber, :release, System.get_env("RELEASE_REVISION") || release_revision.()

  if dir = System.get_env("UMBER_UPLOADS_DIR") do
    config :umber, :uploads_dir, dir
  end

  if subject = System.get_env("VAPID_SUBJECT") do
    config :umber, :vapid,
      subject: subject,
      public_key: System.fetch_env!("VAPID_PUBLIC_KEY"),
      private_key: System.fetch_env!("VAPID_PRIVATE_KEY")
  end

  if key = System.get_env("UMBER_STAFF_TRIAL_KEY") do
    config :umber, :staff_trial_key, key
  end
end
