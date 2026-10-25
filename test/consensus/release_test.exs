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

  # D-058's rebuild of `activity_groups`, and the migration just before it.
  @accountless_organizers 20_261_024_012_242
  @add_search_area 20_260_811_172_739

  # `activity_groups` as every migration up to `@add_search_area` leaves it, in column
  # order. The rebuild must reproduce this exactly plus `anonymous_organizer_id`, and its
  # `down` must put back exactly this.
  @pre_d058_group_columns ~w(
    id title slug status activity_type deadline_at anonymous veto_allowed
    expected_voter_count completed_at cancelled_at organizer_id inserted_at updated_at
    resolution resolved_activity_id resolved_at search_area search_bbox
  )

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
    # Deliberately generic: whichever migration is newest, reversing it must touch that
    # one and nothing else. What a *particular* `down` has to restore is asserted in
    # that migration's own describe, so adding a migration never turns this red.
    test "reverses exactly the newest migration when handed its version", %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)
      Consensus.Release.migrate()

      [last, previous | _] = Enum.reverse(migration_versions())

      assert {:ok, [^last], _} = Consensus.Release.rollback(TmpRepo, last)

      applied = database |> query("SELECT version FROM schema_migrations") |> List.flatten()
      refute last in applied
      assert previous in applied
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

  describe "the accountless-organizer migration (D-058)" do
    test "rebuilds activity_groups with two nullable owners and the ownership CHECK",
         %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)
      Consensus.Release.migrate()

      # Column for column the pre-D-058 table plus `anonymous_organizer_id`, in the
      # order the literal `CREATE TABLE` writes them — pinned so a hand-copied DDL that
      # drops or renames a real column fails here rather than in production.
      assert columns(database, "activity_groups") ==
               List.insert_at(
                 @pre_d058_group_columns,
                 Enum.find_index(@pre_d058_group_columns, &(&1 == "organizer_id")) + 1,
                 "anonymous_organizer_id"
               )

      assert not_null(database, "activity_groups", "organizer_id") == 0
      assert not_null(database, "activity_groups", "anonymous_organizer_id") == 0
      assert check_constraint?(database, "activity_groups", "organizer_xor_anonymous_organizer")

      # CASCADE keeps `Accounts.delete_user/2` taking an organizer's groups with them
      # (invariant 5); RESTRICT makes a wrong boot-sweep predicate raise instead of
      # cascading through groups and votes.
      assert foreign_keys(database, "activity_groups") == [
               {"anonymous_organizer_id", "anonymous_organizers", "RESTRICT"},
               {"organizer_id", "users", "CASCADE"},
               {"resolved_activity_id", "activities", "SET NULL"}
             ]

      assert indexes(database, "activity_groups") == [
               "activity_groups_anonymous_organizer_id_index",
               "activity_groups_organizer_id_index",
               "activity_groups_resolved_activity_id_index",
               "activity_groups_slug_index"
             ]

      assert columns(database, "anonymous_organizers") == [
               "id",
               "token_hash",
               "display_name",
               "claimed_by_user_id",
               "claimed_at",
               "last_seen_at",
               "inserted_at",
               "updated_at"
             ]

      assert not_null(database, "anonymous_organizers", "token_hash") == 1
      assert not_null(database, "anonymous_organizers", "last_seen_at") == 1
      assert not_null(database, "anonymous_organizers", "display_name") == 0

      assert foreign_keys(database, "anonymous_organizers") == [
               {"claimed_by_user_id", "users", "SET NULL"}
             ]

      assert indexes(database, "anonymous_organizers") == [
               "anonymous_organizers_claimed_by_user_id_index",
               "anonymous_organizers_token_hash_index"
             ]
    end

    # The wipe is the decision (owner, 2026-10-23), so this pins that it is a *clean*
    # one: every group, option, participant and vote gone through the cascades, nothing
    # orphaned, and foreign keys still on afterwards on the connection that ran it. A
    # `PRAGMA foreign_keys = OFF` rebuild fails all three — `DROP TABLE` cascades nothing
    # with enforcement off, so `activities` survive pointing at a group id the next
    # insert reuses. `pool_size: 1`, like the boot-time migrator's connection.
    test "wipes a populated database cleanly, with foreign keys on throughout",
         %{tmp_dir: tmp} do
      configure_tmp_repo(tmp)
      start_supervised!(TmpRepo)

      Ecto.Migrator.run(TmpRepo, :up, to: @add_search_area, log: false)
      refute "anonymous_organizers" in repo_tables()

      now = "2026-10-23T12:00:00"

      insert_user!(now)

      sql!("""
      INSERT INTO feedback (mood, message, user_id, inserted_at, updated_at)
      VALUES ('happy', 'survives the wipe', 1, '#{now}', '#{now}')
      """)

      sql!("""
      INSERT INTO activity_groups (id, title, slug, status, organizer_id, completed_at, inserted_at, updated_at)
      VALUES (1, 'Friday dinner', 'abcdefg', 'completed', 1, '#{now}', '#{now}', '#{now}')
      """)

      for {id, position, name} <- [{1, 0, "Vernick"}, {2, 1, "Zahav"}] do
        sql!("""
        INSERT INTO activities (id, group_id, position, name, added_by_id, inserted_at, updated_at)
        VALUES (#{id}, 1, #{position}, '#{name}', 1, '#{now}', '#{now}')
        """)
      end

      # The circular reference: the group points at one of its own activities.
      sql!("""
      UPDATE activity_groups
      SET resolution = 'organizer_pick', resolved_activity_id = 2, resolved_at = '#{now}'
      WHERE id = 1
      """)

      sql!("""
      INSERT INTO participants (id, group_id, display_name, kind, token, voted_at, inserted_at, updated_at)
      VALUES (1, 1, 'Sam', 'guest', 'participant-token', '#{now}', '#{now}', '#{now}')
      """)

      for {activity_id, kind} <- [{1, "veto"}, {2, "approve"}] do
        sql!("""
        INSERT INTO votes (participant_id, activity_id, kind, inserted_at, updated_at)
        VALUES (1, #{activity_id}, '#{kind}', '#{now}', '#{now}')
        """)
      end

      for table <- ~w(activity_groups activities participants votes) do
        assert count(table) > 0, "#{table} was not populated before the migration"
      end

      # `to:`, not `all: true`: only D-058 is under test, and a later migration must not
      # change what this call returns.
      assert [@accountless_organizers] ==
               Ecto.Migrator.run(TmpRepo, :up, to: @accountless_organizers, log: false)

      for table <- ~w(activity_groups activities participants votes anonymous_organizers) do
        assert count(table) == 0, "#{table} still has rows after the wipe"
      end

      # What the wipe deliberately keeps.
      assert count("users") == 1
      assert count("feedback") == 1

      assert sql!("PRAGMA foreign_key_check").rows == []
      assert sql!("PRAGMA foreign_keys").rows == [[1]]

      # The CHECK, against raw inserts that bypass every changeset.
      sql!("""
      INSERT INTO anonymous_organizers (id, token_hash, last_seen_at, inserted_at, updated_at)
      VALUES (1, randomblob(32), '#{now}', '#{now}', '#{now}')
      """)

      insert_group = fn slug, organizer_id, anonymous_organizer_id ->
        TmpRepo.query(
          """
          INSERT INTO activity_groups (title, slug, organizer_id, anonymous_organizer_id, inserted_at, updated_at)
          VALUES ('t', ?, ?, ?, '#{now}', '#{now}')
          RETURNING id
          """,
          [slug, organizer_id, anonymous_organizer_id],
          log: false
        )
      end

      # The sequence survived the rebuild: the wiped group was id 1, and a feedback row
      # that outlived it may still link to `/groups/1/...`, so the next group is id 2.
      assert {:ok, %{rows: [[2]]}} = insert_group.("user-owned", 1, nil)
      assert {:ok, %{rows: [[3]]}} = insert_group.("anon-owned", nil, 1)

      assert {:error, %Exqlite.Error{message: both}} = insert_group.("both", 1, 1)
      assert both =~ "CHECK constraint failed: organizer_xor_anonymous_organizer"

      assert {:error, %Exqlite.Error{message: neither}} = insert_group.("neither", nil, nil)
      assert neither =~ "CHECK constraint failed: organizer_xor_anonymous_organizer"

      # RESTRICT: an anonymous organizer that still owns a group cannot be deleted.
      assert {:error, %Exqlite.Error{message: restricted}} =
               TmpRepo.query("DELETE FROM anonymous_organizers WHERE id = 1", [], log: false)

      assert restricted =~ "FOREIGN KEY constraint failed"
      assert count("activity_groups") == 2
    end

    # `:down, to:` reverses D-058 *and everything after it*, so this keeps asserting the
    # pre-D-058 shape however many migrations land later.
    test "its down puts back the pre-D-058 table and drops anonymous_organizers",
         %{tmp_dir: tmp} do
      database = configure_tmp_repo(tmp)
      Consensus.Release.migrate()
      start_supervised!(TmpRepo)

      assert @accountless_organizers in Ecto.Migrator.run(TmpRepo, :down,
               to: @accountless_organizers,
               log: false
             )

      # `organizer_id NOT NULL`, no `anonymous_organizer_id`, no CHECK, the three
      # original index names — and `anonymous_organizers` gone, which is also the only
      # assertion that its `down` runs. Everything an earlier migration created stays:
      # the Assisted Add search columns, the endgame resolution columns and the
      # feedback/voting tables included.
      assert columns(database, "activity_groups") == @pre_d058_group_columns
      assert not_null(database, "activity_groups", "organizer_id") == 1
      refute check_constraint?(database, "activity_groups", "organizer_xor_anonymous_organizer")

      assert foreign_keys(database, "activity_groups") == [
               {"organizer_id", "users", "CASCADE"},
               {"resolved_activity_id", "activities", "SET NULL"}
             ]

      assert indexes(database, "activity_groups") == [
               "activity_groups_organizer_id_index",
               "activity_groups_resolved_activity_id_index",
               "activity_groups_slug_index"
             ]

      tables = tables(database)
      refute "anonymous_organizers" in tables
      assert "feedback" in tables
      assert "participants" in tables
      assert "votes" in tables
      assert "activity_groups" in tables
      assert "activities" in tables
      assert "users" in tables
    end

    # `DROP TABLE` resets an AUTOINCREMENT table's `sqlite_sequence` row; the `down`
    # carries it across exactly as the `up` does, so a rollback cannot hand an old
    # group's id — still named by a surviving feedback row's `page_path` — to a new one.
    test "its down keeps the activity_groups id sequence", %{tmp_dir: tmp} do
      configure_tmp_repo(tmp)
      Consensus.Release.migrate()
      start_supervised!(TmpRepo)

      now = "2026-10-23T12:00:00"
      insert_user!(now)

      sql!("""
      INSERT INTO activity_groups (id, title, slug, organizer_id, inserted_at, updated_at)
      VALUES (7, 'Friday dinner', 'abcdefg', 1, '#{now}', '#{now}')
      """)

      Ecto.Migrator.run(TmpRepo, :down, to: @accountless_organizers, log: false)
      assert count("activity_groups") == 0

      assert %{rows: [[8]]} =
               sql!("""
               INSERT INTO activity_groups (title, slug, organizer_id, inserted_at, updated_at)
               VALUES ('t', 'after-down', 1, '#{now}', '#{now}')
               RETURNING id
               """)
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

  # Read-only schema queries against the file itself, through a raw connection rather
  # than a repo, so they work whether or not anything has the database open.
  defp query(database, sql, params \\ []) do
    {:ok, conn} = Exqlite.Sqlite3.open(database)
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(statement, params)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    :ok = Exqlite.Sqlite3.close(conn)
    rows
  end

  defp tables(database) do
    database
    |> query("SELECT name FROM sqlite_master WHERE type = 'table'")
    |> List.flatten()
  end

  defp columns(database, table) do
    database
    |> query("SELECT name FROM pragma_table_info(?) ORDER BY cid", [table])
    |> List.flatten()
  end

  defp not_null(database, table, column) do
    [[notnull]] =
      query(database, ~s|SELECT "notnull" FROM pragma_table_info(?) WHERE name = ?|, [
        table,
        column
      ])

    notnull
  end

  defp foreign_keys(database, table) do
    database
    |> query(~s|SELECT "from", "table", on_delete FROM pragma_foreign_key_list(?)|, [table])
    |> Enum.map(&List.to_tuple/1)
    |> Enum.sort()
  end

  defp indexes(database, table) do
    database
    |> query("SELECT name FROM pragma_index_list(?)", [table])
    |> List.flatten()
    |> Enum.sort()
  end

  # SQLite keeps no catalogue of CHECK constraints; the table's stored DDL is the record.
  defp check_constraint?(database, table, name) do
    [[ddl]] = query(database, "SELECT sql FROM sqlite_master WHERE name = ?", [table])
    ddl =~ ~r/CONSTRAINT\s+"#{name}"\s+CHECK/
  end

  # Through the running TmpRepo, so foreign keys are on exactly as the app's own
  # connections have them (ecto_sqlite3's default; a raw connection defaults to off).
  defp sql!(sql), do: TmpRepo.query!(sql, [], log: false)

  # User 1, the organizer every raw group insert in this file points at.
  defp insert_user!(now) do
    sql!("""
    INSERT INTO users (id, email, username, hashed_password, confirmed_at, is_admin, inserted_at, updated_at)
    VALUES (1, 'organizer@example.com', 'organizer', NULL, '#{now}', 0, '#{now}', '#{now}')
    """)
  end

  defp count(table) do
    [[n]] = sql!(~s|SELECT count(*) FROM "#{table}"|).rows
    n
  end

  defp repo_tables do
    "SELECT name FROM sqlite_master WHERE type = 'table'"
    |> sql!()
    |> Map.fetch!(:rows)
    |> List.flatten()
  end
end
