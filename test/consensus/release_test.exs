defmodule Consensus.ReleaseTest do
  @moduledoc """
  `Consensus.Release` is what an operator reaches for over `fly ssh console` when the
  automatic boot-time migration has already gone wrong, and it is mix-free code that no
  other test in the suite loads.

  `migrate/0` and `rollback/2` run against a throwaway repo pointed at a database file
  under the test's own tmp directory, so the suite's own database is never migrated,
  rolled back, or otherwise touched by them.
  """
  use Consensus.DataCase, async: false

  @moduletag :tmp_dir

  # Seeding logs a warning while the default bootstrap password is in place, and the
  # preflight warns that the suite's database is not on a mount. Neither is under test.
  @moduletag :capture_log

  defmodule TmpRepo do
    use Ecto.Repo, otp_app: :consensus, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    original_repos = Application.fetch_env!(:consensus, :ecto_repos)

    # Each `migrate/0` recompiles the migration files, and several tests run more than
    # one. Without this every run after the first prints a "redefining module" warning.
    ignore_conflict? = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    on_exit(fn ->
      Code.put_compiler_option(:ignore_module_conflict, ignore_conflict?)
      Application.put_env(:consensus, :ecto_repos, original_repos)
      Application.delete_env(:consensus, TmpRepo)
    end)

    :ok
  end

  describe "migrate/0" do
    test "applies every migration to every configured repo", %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)

      assert [{:ok, applied, _started_apps}] = Consensus.Release.migrate()
      assert applied == migration_versions()

      tables = tables(database)
      assert "users" in tables
      assert "users_tokens" in tables
      assert "activity_groups" in tables
      assert "activities" in tables
      assert "schema_migrations" in tables
      # Created by an early migration and dropped by the newest one. Asserting its
      # absence here is what proves migrate/0 ran the whole chain and not a prefix.
      refute "home_page" in tables
    end

    test "is idempotent — a second run has nothing to apply", %{tmp_dir: tmp} do
      configure_tmp_repo(tmp)

      assert [{:ok, applied, _}] = Consensus.Release.migrate()
      assert applied != []
      assert [{:ok, [], _}] = Consensus.Release.migrate()
    end
  end

  describe "rollback/2" do
    test "takes the given repo back down to the given version", %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)
      Consensus.Release.migrate()

      last = List.last(migration_versions())

      assert {:ok, [^last], _} = Consensus.Release.rollback(TmpRepo, last)

      # The newest migration adds the resolution columns to `activity_groups` (the
      # endgame screens), so reversing exactly that one has to take them away — which
      # is also the only assertion that its `down` runs — while leaving everything an
      # earlier migration created in place, the feedback and voting tables included.
      columns = columns(database, "activity_groups")
      refute "resolution" in columns
      refute "resolved_activity_id" in columns
      refute "resolved_at" in columns

      tables = tables(database)
      assert "feedback" in tables
      assert "participants" in tables
      assert "votes" in tables
      assert "activity_groups" in tables
      assert "activities" in tables
      assert "users" in tables
    end

    test "reverses a migration in the middle of the chain, and everything after it",
         %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)
      Consensus.Release.migrate()

      # `drop_home_page` is the one migration in this repo whose `down/0` has real work
      # to do — it recreates a table with a named CHECK constraint from literal SQL,
      # because the `create constraint(...)` DSL compiles fine and only raises when a
      # rollback actually runs it. `rollback/2` reverses everything after *and
      # including* the version it is given, so asking for that one also unwinds every
      # migration added since.
      drop_home_page = 20_260_808_183_755
      assert drop_home_page in migration_versions()

      assert {:ok, reverted, _} = Consensus.Release.rollback(TmpRepo, drop_home_page)
      assert drop_home_page in reverted

      tables = tables(database)
      assert "home_page" in tables
      assert "users" in tables
      refute "participants" in tables
    end

    test "rolling back to 0 reverses the whole schema", %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)
      Consensus.Release.migrate()

      assert {:ok, reverted, _} = Consensus.Release.rollback(TmpRepo, 0)
      assert Enum.sort(reverted) == migration_versions()

      tables = tables(database)
      refute "users" in tables
      refute "home_page" in tables
      refute "activity_groups" in tables
      refute "activities" in tables
    end
  end

  describe "seed/0" do
    test "runs the idempotent seeds against the configured repo" do
      # Deliberately not the tmp repo: `Consensus.Seeds` writes through
      # `Consensus.Repo`, which the sandbox rolls back at the end of this test.
      assert [{:ok, {:ok, %{admin: admin}}, _}] = Consensus.Release.seed()

      assert admin.is_admin
      assert admin.confirmed_at
      assert Consensus.Accounts.count_admins() == 1

      # Idempotent: the second run finds an admin and creates nothing.
      assert [{:ok, {:ok, %{admin: nil}}, _}] = Consensus.Release.seed()
      assert Consensus.Accounts.count_admins() == 1
    end
  end

  describe "the boot preflight" do
    # Deleting `preflight!/1` from any of the three used to leave the whole suite green
    # while `decisions.md` went on stating as fact that they run it. Each test points the
    # repo's database inside a regular file, which no user — root included — can turn
    # into a directory, and then asserts both that the preflight message surfaced *and*
    # that no database file was created, i.e. that it ran before anything opened the repo.
    test "migrate/0 preflights before it opens the repo", %{tmp_dir: tmp} do
      database = break_tmp_repo(tmp)

      assert_raise RuntimeError, ~r/Cannot write the SQLite database/, fn ->
        Consensus.Release.migrate()
      end

      refute File.exists?(database)
    end

    test "seed/0 preflights before it opens the repo", %{tmp_dir: tmp} do
      database = break_tmp_repo(tmp)

      assert_raise RuntimeError, ~r/Cannot write the SQLite database/, fn ->
        Consensus.Release.seed()
      end

      refute File.exists?(database)
    end

    test "rollback/2 preflights the repo it was handed", %{tmp_dir: tmp} do
      database = break_tmp_repo(tmp)

      assert_raise RuntimeError, ~r/Cannot write the SQLite database/, fn ->
        Consensus.Release.rollback(TmpRepo, 0)
      end

      refute File.exists?(database)
    end
  end

  # Points TmpRepo's database inside a regular file, so the preflight fails on it and
  # nothing else in the suite is disturbed — in particular `Consensus.Repo`'s own
  # configuration, which the running sandbox pool depends on, is never touched.
  defp break_tmp_repo(tmp) do
    blocker = Path.join(tmp, "not-a-directory")
    File.write!(blocker, "")

    database = Path.join(blocker, "release_test.db")

    Application.put_env(:consensus, TmpRepo, database: database, priv: "priv/repo", pool_size: 1)
    Application.put_env(:consensus, :ecto_repos, [TmpRepo])

    database
  end

  defp configure_tmp_repo(tmp) do
    database = Path.join(tmp, "release_test.db")

    Application.put_env(:consensus, TmpRepo,
      database: database,
      # The real migrations, not `priv/tmp_repo/migrations`.
      priv: "priv/repo",
      pool_size: 1
    )

    Application.put_env(:consensus, :ecto_repos, [TmpRepo])

    database
  end

  defp migration_versions do
    "priv/repo/migrations/*.exs"
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))
    |> Enum.sort()
  end

  defp tables(database) do
    {:ok, conn} = Exqlite.Sqlite3.open(database)

    {:ok, statement} =
      Exqlite.Sqlite3.prepare(conn, "SELECT name FROM sqlite_master WHERE type = 'table'")

    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    :ok = Exqlite.Sqlite3.close(conn)

    List.flatten(rows)
  end

  defp columns(database, table) do
    {:ok, conn} = Exqlite.Sqlite3.open(database)

    {:ok, statement} =
      Exqlite.Sqlite3.prepare(conn, "SELECT name FROM pragma_table_info(?)")

    :ok = Exqlite.Sqlite3.bind(statement, [table])
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    :ok = Exqlite.Sqlite3.close(conn)

    List.flatten(rows)
  end
end
