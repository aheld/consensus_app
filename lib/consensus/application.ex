defmodule Consensus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    preflight!()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Consensus.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc """
  The supervision tree as a plain list, built but not started.

  Public on purpose. Deleting the `Ecto.Migrator` child, deleting the `Consensus.Seeds`
  child, or moving either of them after `ConsensusWeb.Endpoint` is a production outage
  that no request-level test can observe: this app has no `[deploy] release_command`
  (see docs/decisions.md D-009), so this list is the *only* thing that migrates a
  release, and the Seeds child is the only thing that gives a fresh deploy an
  administrator (D-010). `test/consensus/application_test.exs` asserts the shape.
  """
  def children do
    [
      ConsensusWeb.Telemetry,
      Consensus.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:consensus, :ecto_repos), skip: skip_migrations?()},
      # Must stay directly after Ecto.Migrator: both run synchronously during
      # supervisor init and return :ignore, so by the time the endpoint below starts,
      # the schema is current and the bootstrap admin exists. This is how the app
      # satisfies "migrations and seeding run automatically in the deploy flow" on
      # Fly.io, where a SQLite volume rules out a `release_command`. See docs/decisions.md.
      {Consensus.Seeds, skip: skip_seeds?()},
      {DNSCluster, query: Application.get_env(:consensus, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Consensus.PubSub},
      # Start a worker by calling: Consensus.Worker.start_link(arg)
      # {Consensus.Worker, arg},
      # Owns the ETS table Consensus.LinkPreview.fetch/1 caches into. No database
      # dependency, so it only needs to start after Consensus.Repo and before
      # ConsensusWeb.Endpoint (both true here); test/consensus/application_test.exs
      # asserts that range rather than an exact index.
      Consensus.LinkPreview.Cache,
      # The Discovery instance of the same parameterised cache (a second child of
      # Consensus.LinkPreview.Cache under its own table — see that module and
      # docs/research/activity-discovery.md §4.5). Starting it validates the
      # provider registry, so an adapter whose cache_policy forbids storing
      # results cannot boot. Same start-range constraint as the child above;
      # test/consensus/application_test.exs asserts it.
      Consensus.Discovery.Cache,
      # Start to serve requests, typically the last entry
      ConsensusWeb.Endpoint
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConsensusWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @doc """
  True when this boot must not run migrations.

  The one signal is `RELEASE_NAME`, which only a release sets: `mix phx.server` and the
  test suite manage their own schema through Mix tasks, a release has no Mix. Inverting
  this is silent — the suite stays green and the first production request answers
  `no such table: users`.
  """
  def skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  @doc """
  True when this boot must not seed.

  Seeds whenever we migrate. Outside a release the developer gets the same data from
  `mix ecto.setup`, which runs priv/repo/seeds.exs; the test suite must never be seeded
  behind ExUnit's back, so config/test.exs pins `:seed_on_boot` to `false`.
  """
  def skip_seeds? do
    case Application.get_env(:consensus, :seed_on_boot) do
      nil -> skip_migrations?()
      seed? -> not seed?
    end
  end

  # Runs before `Consensus.Repo` is in the tree, and only where this app owns the
  # database file rather than a Mix task — i.e. exactly when we are about to migrate.
  # See `Consensus.BootCheck` for what it catches and why the Ecto error it replaces
  # sends operators to the wrong place.
  defp preflight! do
    if skip_migrations?(), do: :ok, else: Consensus.BootCheck.run!()
  end
end
