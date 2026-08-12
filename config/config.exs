# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :consensus, :scopes,
  user: [
    default: true,
    module: Consensus.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Consensus.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :consensus,
  ecto_repos: [Consensus.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :consensus, ConsensusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # `root_layout` rather than the generator's `layout: false`: `ConsensusWeb.ErrorHTML`'s
  # 404 and 500 templates render the global chrome (D-041), and without the root layout
  # they would come back as a bare fragment with no `<head>` — and so no stylesheet.
  render_errors: [
    formats: [html: ConsensusWeb.ErrorHTML, json: ConsensusWeb.ErrorJSON],
    root_layout: {ConsensusWeb.Layouts, :root},
    layout: false
  ],
  pubsub_server: Consensus.PubSub,
  live_view: [signing_salt: "15BUGAY7"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Local

# Consensus.LinkPreview fetches OpenGraph/HTML metadata for a pasted URL through this
# module (config/test.exs points it at a stub instead). cache_ttl_ms / cache_error_ttl_ms
# are read by Consensus.LinkPreview.Cache and default to 6 hours / 5 minutes when unset.
config :consensus, Consensus.LinkPreview, fetcher: Consensus.LinkPreview.Fetcher.Req

# The Consensus.Discovery provider registry: activity type => {adapter, opts}, read
# with Map.get/3 and never branched on (CLAUDE.md product invariant 2; the shape is
# docs/research/activity-discovery.md §4.4). Four types resolve to the SAME module
# with different tag data — the invariant-12 proof: there is no per-type code for a
# branch to live in. An unregistered type falls through to {:ok, []} and the
# typed/paste path. config/test.exs replaces this map with a stub registry, so the
# live adapter is never reached from the suite.
config :consensus, Consensus.Discovery,
  providers: %{
    "restaurant" => {Consensus.Discovery.Provider.Overpass, tags: [{"amenity", "restaurant"}]},
    "bar" => {Consensus.Discovery.Provider.Overpass, tags: [{"amenity", "bar"}]},
    "bowling" => {Consensus.Discovery.Provider.Overpass, tags: [{"leisure", "bowling_alley"}]},
    "cinema" => {Consensus.Discovery.Provider.Overpass, tags: [{"amenity", "cinema"}]}
  }

# The Overpass adapter's HTTP seam (config/test.exs points it at a stub instead).
config :consensus, Consensus.Discovery.Provider.Overpass,
  http: Consensus.Discovery.Provider.Overpass.HTTP.Req

# The IANA time zone database behind `DateTime.new/4` and `DateTime.shift_zone/2`, which
# `Consensus.Deadlines` needs to turn an organizer's wall-clock deadline into a real
# instant (D-055). Elixir's default is `Calendar.UTCOnlyTimeZoneDatabase`, which answers
# `{:error, :utc_only_time_zone_database}` for every named zone.
#
# `:tz` compiles the database in at BUILD time. Its updater processes
# (`Tz.UpdatePeriodically`, `Tz.WatchPeriodically`) are deliberately NOT in
# `Consensus.Application`'s supervision tree: D-031 rejected a zone database over "a
# runtime data download, a periodic updater, and a new failure mode at boot", and all
# three of those objections are about the updater, not the data. The data goes stale
# between deploys and refreshes on the next one — accepted, and the honest cost of not
# running an updater. See docs/plans/custom-deadline.md §3.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  consensus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  consensus: [
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
