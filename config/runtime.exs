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
#     PHX_SERVER=true bin/consensus start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :consensus, ConsensusWeb.Endpoint, server: true
end

config :consensus, ConsensusWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :consensus, ConsensusWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/consensus_web/router\.ex$"E,
        ~r"lib/consensus_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/consensus/consensus.db
      """

  config :consensus, Consensus.Repo,
    database: database_path,
    # SQLite serialises writes: extra pool slots only ever help concurrent readers.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # Both are ecto_sqlite3 defaults; stated explicitly because they are load-bearing
    # on a single Fly machine. WAL lets readers run while a write is in flight, and
    # the busy timeout makes a contended write wait instead of returning
    # "** (Exqlite.Error) database is locked".
    journal_mode: :wal,
    busy_timeout: 5_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :consensus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :consensus, ConsensusWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :consensus, ConsensusWeb.Endpoint,
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
  #     config :consensus, ConsensusWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # This app deliberately ships without a production mail provider, and works without
  # one: registration takes a password and signs the new account in immediately, so
  # nobody is ever blocked waiting for an email.
  #
  # It still needs an adapter that *works*, though. The generated default is
  # `Swoosh.Adapters.Local` (config/config.exs), which pushes to a GenServer that
  # config/prod.exs deliberately does not start (`config :swoosh, local: false`) —
  # so in a release every delivery exits with
  #
  #     ** (exit) exited in: GenServer.call({:global, Swoosh.Adapters.Local.Storage.Memory}, ...)
  #
  # taking the calling process down with it. `Swoosh.Adapters.Logger` is the documented
  # adapter for "environments where you do not necessarily want to send real emails":
  # delivery always succeeds and logs the recipient (not the body, so no magic-link
  # token reaches the logs). `Consensus.Accounts.UserNotifier` additionally refuses to
  # let any mailer failure escape into a web request.
  config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Logger, level: :info

  # To send real email, configure a provider below — these lines come after the default
  # above, so they win. Example for Mailgun:
  #
  #     config :consensus, Consensus.Mailer,
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
