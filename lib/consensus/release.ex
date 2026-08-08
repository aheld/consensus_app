defmodule Consensus.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  Every entry point here — `migrate/0`, `seed/0` and `rollback/2` alike — runs the
  `Consensus.BootCheck` preflight against the repo it is about to open, before it opens
  it. These commands run in a *fresh* node via `bin/consensus eval`, which never goes
  through `Consensus.Application.start/2`, and they are precisely what an operator
  reaches for when something is already wrong — so without this they would report an
  unwritable volume as a connection-pool error.
  """
  @app :consensus

  @doc """
  Runs every pending migration for every configured repo.

  Not part of the deploy path: `fly.toml` deliberately has no `[deploy]
  release_command` (a release machine has no volume mounted), so a release migrates
  from the supervision tree instead. See `Consensus.Application.children/0`.
  """
  def migrate do
    load_app()
    Enum.each(repos(), &preflight!/1)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Runs the idempotent seeds (bootstrap admin + home page row).

  Requires an already-migrated database — it does not migrate for you, and on an
  unmigrated one it fails with a raw `Exqlite.Error` about a missing table. Run
  `migrate/0` (or `/app/bin/migrate`) first.

  You do not normally need this at all: `Consensus.Application` migrates and then seeds
  on every release boot. It exists for the times you are already on the machine, e.g.

      fly ssh console -C "/app/bin/consensus eval 'Consensus.Release.seed()'"
  """
  def seed do
    load_app()
    Enum.each(repos(), &preflight!/1)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo -> Consensus.Seeds.run!() end)
    end
  end

  @doc """
  Rolls `repo` back down to (and including) `version`.

  Destructive and not covered by any backup this app takes for you — snapshot the
  volume first (`fly volumes snapshots create`).
  """
  def rollback(repo, version) do
    load_app()
    preflight!(repo)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Runs the boot preflight against `repo`'s *own* configured database file.
  #
  # `Consensus.BootCheck.run!/0` checks whatever `Consensus.Repo` is configured with,
  # which is the right file for every release — `:ecto_repos` has exactly one entry —
  # but not for a repo handed to `rollback/2` by name. Checking the repo we are about to
  # open keeps the message about the file that will actually fail, and keeps all three
  # entry points here honest with one implementation. A repo with no `:database` (there
  # is none today) is left to fail on its own terms rather than silently skipped past a
  # check that would not apply to it.
  defp preflight!(repo) do
    case Application.get_env(@app, repo)[:database] do
      nil -> :ok
      database -> Consensus.BootCheck.run!(database)
    end
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
