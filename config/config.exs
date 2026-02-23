# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Pepe keeps no database by default - model connections, agents and gateway
# credentials live in a JSON config file (see Pepe.Config). Ecto deps remain
# available if you want to add persistence later.
config :pepe,
  ecto_repos: [],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :pepe, PepeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PepeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pepe.PubSub,
  live_view: [signing_salt: "oUKCzGru"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :pepe, Pepe.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pepe: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  pepe: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Timezone database (used by scheduled tasks / cron for "America/Sao_Paulo" etc.).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Fixed system messages (CLI/gateway) are translated via Pepe.Gettext. The
# active locale comes from the config file (`mix pepe setup`); the agent's own
# replies are unaffected and follow the user's language.
config :pepe, Pepe.Gettext, default_locale: "en", locales: ~w(en pt_BR pt_PT es)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
