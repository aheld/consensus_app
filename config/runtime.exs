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

# ASSIST_LIVE=1 swaps dev's Assisted Add registry from the scripted provider
# (config/dev.exs) back to the real Overpass adapter — the same map prod uses
# (config/config.exs). Registry resolution stays data in config either way
# (invariant 12); runtime.exs runs after dev.exs, so this wins when set.
if config_env() == :dev and System.get_env("ASSIST_LIVE") == "1" do
  config :consensus, Consensus.Discovery,
    providers: %{
      "restaurant" => {Consensus.Discovery.Provider.Overpass, tags: [{"amenity", "restaurant"}]},
      "bar" => {Consensus.Discovery.Provider.Overpass, tags: [{"amenity", "bar"}]},
      "bowling" => {Consensus.Discovery.Provider.Overpass, tags: [{"leisure", "bowling_alley"}]},
      "cinema" => {Consensus.Discovery.Provider.Overpass, tags: [{"amenity", "cinema"}]}
    }
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
    # ONE connection by default, deliberately — D-038 supersedes D-013's claim that extra
    # pool slots "only ever help concurrent readers". They do not: SQLite permits one write
    # transaction across the whole file, so the slots race a lock that was never shareable,
    # and SQLite's busy handler is documented to be unfair about which waiter wins. Measured
    # on a 15-voter deadline burst at production's own settings — pool 5 → p95 25,762ms with
    # ballots lost to a 5s busy timeout; pool 1 → p95 10.6ms, zero refusals, and the read
    # tail improved too (5,431ms → 15.6ms). Raise POOL_SIZE only with a measurement in hand.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1"),
    # Both are ecto_sqlite3 defaults; stated explicitly because they are load-bearing
    # on a single Fly machine. WAL lets readers run while a write is in flight, and
    # the busy timeout makes a contended write wait instead of returning
    # "** (Exqlite.Error) database is locked".
    # `BEGIN IMMEDIATE` rather than ecto_sqlite3's default `BEGIN DEFERRED`. A deferred
    # transaction takes no write lock at `BEGIN` and asks for one on its first write — and if
    # another writer holds it by then, SQLite cannot wait (this connection already holds a read
    # snapshot, so blocking could deadlock the pair). It returns `SQLITE_BUSY` at once and the
    # `busy_timeout` handler never runs. Taking the lock up front is what lets `busy_timeout`
    # do its job, so two simultaneous organizer writes queue instead of one 500ing. D-033.
    default_transaction_mode: :immediate,
    journal_mode: :wal,
    busy_timeout: 5_000,
    # Pinned rather than inherited — `:normal` is already the ecto_sqlite3/exqlite default,
    # so this changes nothing today. It makes the durability trade explicit: under WAL,
    # `:normal` fsyncs at checkpoint rather than at every commit, so a BEAM crash or a
    # `fly deploy` cannot lose a committed ballot, but a host power loss or kernel panic
    # can lose the tail of the WAL. Accepted for a single-machine app whose real durability
    # exposure is the volume snapshot's 24h RPO, not fsync timing. D-038.
    synchronous: :normal

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
  # The provider is Resend (D-039), selected just below — but only when `RESEND_API_KEY`
  # exists. This default is what runs until it does, and the app is designed to work in
  # that state: registration takes a password and signs the new account in immediately,
  # so nobody is ever blocked waiting for an email.
  #
  # The fallback still needs an adapter that *works*, though. The generated default is
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

  # Resend is the provider (D-039). It is configured **only when `RESEND_API_KEY` is
  # present**, and the `Swoosh.Adapters.Logger` default above stays in force when it is
  # not. That conditional is deliberate, not defensive noise:
  #
  #   * The app must stay deployable before the secret exists. `SECRET_KEY_BASE` raises
  #     at boot because nothing works without it; mail is the opposite — invariant 9 says
  #     delivery is best-effort and must never fail a request, so a missing mail key must
  #     never cost you a boot. Raising here would make the first deploy of this change
  #     fail on a machine that has no secret set yet.
  #   * A silent fallback is worse than a loud one. If the key is absent, the log line
  #     below is the only thing that will tell you why a magic link never arrived, so it
  #     is a `warning` and it names the fix.
  #
  # `Swoosh.ApiClient.Req` is already set in config/prod.exs, and `req` is a real
  # dependency — the Resend adapter needs an API client and will not work without one.
  case System.get_env("RESEND_API_KEY") do
    key when is_binary(key) and key != "" ->
      config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Resend, api_key: key

    _ ->
      # The empty stacktrace keeps this to the message itself — a config warning that
      # prints a stack of `:elixir.eval_external_handler/3` frames reads like a crash.
      IO.warn(
        """
        RESEND_API_KEY is not set, so no mail will actually be delivered.

        Consensus.Mailer is falling back to Swoosh.Adapters.Logger: deliveries "succeed"
        and log their recipient, but nothing reaches an inbox. Magic-link login and the
        confirm-your-email-change flow therefore reach nobody. Registration is unaffected —
        it takes a password and signs the account in immediately.

            fly secrets set RESEND_API_KEY=re_...
        """,
        []
      )
  end

  # Resend refuses a `From` whose domain is not verified in its dashboard, so the sender
  # tracks the deployment rather than being baked into the source. Falls back to Resend's
  # `onboarding@resend.dev`, the one address any account may send from unverified — see
  # `Consensus.Accounts.UserNotifier.sender/0`.
  if from = System.get_env("MAIL_FROM") do
    config :consensus, :mail_from, {System.get_env("MAIL_FROM_NAME") || "Consensus", from}
  end

  # To use a different provider instead, configure it here — these lines come after the
  # default above, so they win. Most non-SMTP adapters require an API client; Swoosh
  # supports Req, Hackney and Finch out of the box, configured in config/prod.exs.
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
