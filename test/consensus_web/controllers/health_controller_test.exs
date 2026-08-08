defmodule ConsensusWeb.HealthControllerTest do
  @moduledoc """
  `/health` is what `[[http_service.checks]]` in fly.toml polls, so these tests guard
  two separate things.

  **That it can actually fail.** The endpoint used to run `SELECT 1`, a constant
  expression SQLite answers without opening a single table — a database with no schema
  passed it, so a release whose boot-time `Ecto.Migrator` never ran deployed green while
  `GET /` returned 500. The tests below break the database from inside the sandbox
  transaction (which rolls back at the end of the test) and assert 503.

  **That it is reachable.** Fly's checker connects over plain HTTP to the machine's
  private address with no session and no CSRF token, so the route must sit outside the
  `:browser` pipeline and be on the `force_ssl` exclusion list in `config/prod.exs`.
  Pointing the check at `/` instead would 301 forever and the machine would never report
  healthy.
  """

  # `async: false` is load-bearing, not caution. Proving the endpoint can fail means
  # running DDL (`ALTER TABLE ... RENAME`), and SQLite needs an exclusive lock on the
  # whole database file to do it. Under `async: true` that lock collides with every
  # other sandbox connection still holding a read transaction, and unrelated tests fail
  # with `** (Exqlite.Error) Database busy`. ExUnit runs sync cases only after every
  # async one has finished, so this module gets the file to itself. The DDL still runs
  # inside the sandbox transaction and is rolled back when the test ends.
  use ConsensusWeb.ConnCase, async: false

  # Three of these tests break the database on purpose, and the controller is supposed
  # to log at :error when that happens. Capturing keeps a passing run quiet, so real
  # noise in `mix test` output stays meaningful.
  @moduletag :capture_log

  alias Consensus.Repo

  describe "GET /health" do
    test "answers 200 with no session against a migrated database", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert response(conn, 200) == "ok"
    end

    test "answers 200 when the users table is empty", %{conn: conn} do
      Repo.query!("DELETE FROM users")

      conn = get(conn, ~p"/health")

      assert response(conn, 200) == "ok"
      assert Repo.aggregate(Consensus.Accounts.User, :count) == 0
    end

    test "answers 503 when the application tables are gone", %{conn: conn} do
      # The regression this endpoint was fixed for: `SELECT 1` still succeeds here.
      assert {:ok, _} = Repo.query("SELECT 1", [])
      Repo.query!("ALTER TABLE users RENAME TO users_gone")

      conn = get(conn, ~p"/health")

      assert response(conn, 503) == "database unavailable"
    end

    test "answers 503 when a migration has not been applied", %{conn: conn} do
      Repo.query!(
        "DELETE FROM schema_migrations WHERE version = (SELECT MAX(version) FROM schema_migrations)"
      )

      conn = get(conn, ~p"/health")

      assert response(conn, 503) == "migrations pending"
    end

    test "answers 503 when schema_migrations itself is missing", %{conn: conn} do
      Repo.query!("ALTER TABLE schema_migrations RENAME TO schema_migrations_gone")

      conn = get(conn, ~p"/health")

      assert response(conn, 503) == "database unavailable"
    end

    test "the migration check never creates the schema_migrations table", %{conn: conn} do
      # `Ecto.Migrator.migrations/3` defaults to `skip_table_creation: false`, and
      # `lock_for_migrations/4` then runs `CREATE TABLE IF NOT EXISTS schema_migrations`
      # before reading anything — so the default would take SQLite's single write lock
      # on every poll, i.e. every 30 seconds forever, for a request that is supposed to
      # be a read. The controller passes `skip_table_creation: true`.
      #
      # The previous version of this test renamed the table away and asserted the table
      # was gone without ever issuing a request. That is true for reasons that have
      # nothing to do with the claim — it passes with the controller deleted. The
      # request below is the whole point: it is the only thing that could recreate the
      # table.
      Repo.query!("ALTER TABLE schema_migrations RENAME TO schema_migrations_gone")

      conn = get(conn, ~p"/health")

      # Drop `skip_table_creation: true` and both of these flip: the poll recreates
      # schema_migrations empty, so the query below succeeds, and an empty table reads
      # as "no migration has ever run" — 503 "migrations pending" rather than 503
      # "database unavailable".
      assert response(conn, 503) == "database unavailable"

      assert {:error, %Exqlite.Error{}} =
               Repo.query("SELECT 1 FROM schema_migrations LIMIT 1", [])
    end
  end

  describe "reachability for Fly's checker" do
    test "the route is outside the :browser pipeline" do
      assert %{pipe_through: []} =
               Phoenix.Router.route_info(ConsensusWeb.Router, "GET", "/health", "example.com")

      # Contrast: the public home page does go through :browser, so an empty
      # pipe_through above is a real assertion and not an artefact of route_info.
      assert %{pipe_through: [:browser]} =
               Phoenix.Router.route_info(ConsensusWeb.Router, "GET", "/", "example.com")
    end

    test "it sets no session cookie and no browser security headers", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert response(conn, 200) == "ok"
      assert conn.resp_cookies == %{}
      assert get_resp_header(conn, "content-security-policy") == []
      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "config/prod.exs excludes /health from force_ssl" do
      # Evaluate the production config rather than grepping it: this asserts the value
      # the endpoint would actually be compiled with under MIX_ENV=prod.
      config = Config.Reader.read!("config/prod.exs", env: :prod, target: :host)

      force_ssl = config[:consensus][ConsensusWeb.Endpoint][:force_ssl]

      assert is_list(force_ssl)
      assert force_ssl[:rewrite_on] == [:x_forwarded_proto]
      assert "/health" in force_ssl[:exclude][:paths]
    end

    test "fly.toml points its health check at /health" do
      fly = File.read!("fly.toml")

      assert fly =~ "[[http_service.checks]]"
      assert fly =~ "path = '/health'"
    end
  end
end
