defmodule ConsensusWeb.HealthController do
  @moduledoc """
  Readiness endpoint for Fly's health checker (`[[http_service.checks]]` in fly.toml).

  It asserts that the schema is current and that the application's own tables are
  readable. That distinction matters: `SELECT 1` is a constant expression, so SQLite
  answers it without touching a single table — a database file with no schema at all
  passes it. A release whose boot-time `Ecto.Migrator` never ran would have reported
  200 here while `GET /` returned 500, and the deploy would have gone green.

  So the check is two steps:

    1. `Ecto.Migrator.migrations/3` must report no `:down` migrations. This reads
       `schema_migrations` and lists `priv/repo/migrations` — it is passed
       `skip_table_creation: true` so the check never *writes* (the default would
       `CREATE TABLE IF NOT EXISTS schema_migrations`, and a health check has no
       business taking SQLite's single write lock every 30 seconds). If the table is
       missing entirely the query raises and we answer 503, which is correct.
    2. `SELECT 1 FROM users LIMIT 1` — one page read against a real table (the name is
       taken from `Consensus.Accounts.User.__schema__(:source)` at compile time), correct
       on an empty table, and it fails if the schema is gone or the volume has been
       unmounted underneath us.

  Deliberate trade-off: a 503 pulls the single machine out of Fly Proxy rotation, so a
  broken database is a hard outage rather than a site that quietly 500s. That is the
  intended behaviour — a failed deploy that is visible gets fixed; a green deploy over
  a broken app does not.

  `config/prod.exs` excludes `/health` from `force_ssl`, because the checker connects
  over plain HTTP to the machine's private address and a 301 would never pass, and the
  route sits outside the `:browser` pipeline — it needs no session, CSRF token or layout.
  """

  use ConsensusWeb, :controller

  require Logger

  @repo Consensus.Repo

  # Resolved at compile time from the schema, so renaming the table cannot leave this
  # check quietly querying something that no longer exists.
  @users_table Consensus.Accounts.User.__schema__(:source)

  def index(conn, _params) do
    if pending_migrations?() do
      Logger.error("health check failed: migrations pending")
      send_resp(conn, 503, "migrations pending")
    else
      @repo.query!("SELECT 1 FROM #{@users_table} LIMIT 1")
      send_resp(conn, 200, "ok")
    end
  rescue
    error ->
      Logger.error("health check failed: #{Exception.message(error)}")
      send_resp(conn, 503, "database unavailable")
  catch
    # A dead or draining connection pool exits rather than raising, and an exit is not
    # caught by `rescue`. Same reasoning as Consensus.Accounts.UserNotifier.deliver/3.
    :exit, reason ->
      Logger.error("health check failed: exited with #{inspect(reason)}")
      send_resp(conn, 503, "database unavailable")
  end

  defp pending_migrations? do
    @repo
    |> Ecto.Migrator.migrations([Ecto.Migrator.migrations_path(@repo)],
      skip_table_creation: true
    )
    |> Enum.any?(&match?({:down, _version, _name}, &1))
  end
end
