import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :consensus, Consensus.Repo,
  database: Path.expand("../consensus_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite serialises writes. Without a busy timeout, concurrent async tests
  # surface as "** (Exqlite.Error) database is locked" instead of simply waiting.
  busy_timeout: 5_000,
  # Match dev and prod. WAL lets readers proceed while a writer holds the lock, which is
  # most of what the suite is doing at any moment.
  #
  # This does NOT make concurrent LiveView tests safe, and it was tried: `journal_mode`
  # and `default_transaction_mode: :immediate` both left ~50 of 430 cases failing with
  # `** (Exqlite.Error) Database busy` while `--max-cases 1` passed. The cause is not
  # tuning, it is duration — see the `async:` note in test/support/conn_case.ex. D-033.
  journal_mode: :wal

# The test suite creates exactly the data each test needs. Seeding behind ExUnit's
# back would leak a user into every `Accounts.list_users/0` assertion.
config :consensus, seed_on_boot: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :consensus, ConsensusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CQgTUuBZn4vcymofRgnMggr5vO3PBvY1bmh0eSQS53hTEyHP4DV+s3RBKjp/WLYK",
  server: false

# In test we don't send emails
config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Test

# Consensus.LinkPreview never touches the network in test. The stub lives in
# test/support/link_preview_stub.ex rather than inside one test file, because the LiveView
# tests need it too — and it walks `$callers` so a stub installed by a test is still found
# when `fetch/1` runs inside a `start_async` Task. See its moduledoc.
config :consensus, Consensus.LinkPreview, fetcher: Consensus.LinkPreviewStub

# Consensus.Discovery in test resolves "restaurant" to the $callers-walking stub in
# test/support/discovery_stub.ex (same idiom as Consensus.LinkPreviewStub — a stub a
# test installs survives into start_async Tasks). Its default cache_policy is
# ttl_ms: :none, so tests never share cache entries unless one opts in.
config :consensus, Consensus.Discovery,
  providers: %{"restaurant" => {Consensus.DiscoveryStub, []}}

# Consensus.Discovery.Geocoder never touches the network in test either; the double
# lives in test/support/geocoder_http_stub.ex, same $callers idiom.
config :consensus, Consensus.Discovery.Geocoder, http: Consensus.GeocoderHTTPStub

# Neither does the Overpass adapter: its tests feed it canned Overpass JSON through
# this double (test/support/overpass_http_stub.ex, same $callers idiom). Note the
# providers map above already replaced the prod registry wholesale (Config does not
# deep-merge maps), so nothing in the suite reaches the live adapter by accident.
config :consensus, Consensus.Discovery.Provider.Overpass, http: Consensus.OverpassHTTPStub

# The tie takeover's "Let the app break the tie" shuffle runs the design's clock in
# dev/prod (a 110ms step landing at ~1.9s — `ConsensusWeb.Endgame.Tie`); the suite
# shortens it so the tests that watch the spin land don't sleep through real seconds.
# Not too short, though: the mid-spin refusal tests need a few synchronous clicks to
# fit *inside* the spin, so the landing stays ~100ms out.
config :consensus, endgame_tie_spin_interval_ms: 25, endgame_tie_spin_ticks: 4

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
