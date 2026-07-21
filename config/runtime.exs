import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/pepe start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :pepe, PepeWeb.Endpoint, server: true
end

# A plain OTP release (the Docker image) boots the app directly - there is no
# `mix pepe serve` to flip the server surfaces on, and their defaults are off so a
# CLI one-shot stays fast. `PEPE_SERVE=1` turns on exactly the set that `serve`
# turns on: the HTTP endpoint, the channel gateways, and session persistence.
if System.get_env("PEPE_SERVE") do
  config :pepe,
    serve_endpoint: true,
    start_gateways: true,
    persist_sessions: true

  config :pepe, PepeWeb.Endpoint, server: true
end

config :pepe, PepeWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # Pepe ships as a standalone CLI (escript / Burrito release) and keeps no
  # separate database server - Pepe.Repo is a local SQLite file resolved from
  # PEPE_HOME at boot (see Pepe.Repo.init/2), not from a DATABASE_URL, so there's
  # nothing to configure here. The HTTP endpoint is only used by `pepe serve`; it
  # signs no persistent cookies, so a random per-run secret is fine when
  # SECRET_KEY_BASE isn't provided. This keeps the distributed binary runnable
  # with zero environment setup.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  host = System.get_env("PHX_HOST") || "localhost"

  config :pepe, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :pepe, PepeWeb.Endpoint,
    url: [host: host],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :pepe, PepeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :pepe, PepeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :pepe, Pepe.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
