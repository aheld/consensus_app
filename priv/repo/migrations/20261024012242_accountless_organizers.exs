defmodule Consensus.Repo.Migrations.AccountlessOrganizers do
  use Ecto.Migration

  @moduledoc """
  Lets a group be owned by an organizer with no account (D-058).

  Two changes:

    * **`anonymous_organizers`**, a new table: one row per browser that has organized
      without an account. `token_hash` is the SHA-256 of a server-minted 32-byte token
      the browser holds in its own signed cookie — stored hashed, like `users_tokens`
      and unlike `participants.token`, because it is a write capability and not a ballot
      receipt (D-058 §4). "Anonymous" here means **has no account**; it is unrelated to
      `activity_groups.anonymous`, which is voting secrecy (D-035).
    * **`activity_groups` is rebuilt** so `organizer_id` can be `NULL`, with a new
      `anonymous_organizer_id` beside it and a named CHECK,
      `organizer_xor_anonymous_organizer`, saying exactly one of the two is set.
      SQLite has neither `ALTER COLUMN` nor `ADD CONSTRAINT`, and ecto_sqlite3 raises on
      both rather than emulating them, so the table is dropped and created again from
      literal SQL — the `create_home_page` / `drop_home_page` precedent for a CHECK, not
      `create_activity_groups`, which used the DSL because it needed none.

  **The rebuild is a wipe, and that is the decision, not a shortcut.** Every group is
  deleted first, and with it — by the ordinary `ON DELETE CASCADE`s — every option,
  participant and vote, in production too. Every `/join/:slug` link already pasted into
  a chat starts to 404. Accounts and feedback survive. The owner accepted that on
  2026-10-23 (D-058) in preference to a twelve-step copy-and-swap.

  **Foreign keys stay on, and the whole thing runs in the ordinary DDL transaction.** No
  `@disable_ddl_transaction`, no `PRAGMA`. Both halves are load-bearing:

    * With enforcement **off**, `DROP TABLE` performs no implicit delete, so
      `activities` and `participants` rows survive pointing at group ids that no longer
      exist — and because `DROP TABLE` also resets the `AUTOINCREMENT` sequence, the next
      group #1 silently adopts the old group #1's options and voters (reproduced during
      the plan review). The explicit `DELETE FROM activity_groups` with enforcement on is
      what empties the child tables; the `DROP` then finds nothing to object to.
    * At boot the migrator runs on the already-started `Consensus.Repo`. A `PRAGMA
      foreign_keys = OFF` that a failure left behind would stay off on that connection
      for the life of the process and quietly disable every cascade the app relies on
      (CLAUDE.md invariant 5). Inside a transaction SQLite ignores that pragma anyway.

  Because it is one transaction, a machine killed mid-boot rolls back to the old schema
  with its rows intact, and the next boot runs the whole migration again from the top.

  **The `AUTOINCREMENT` sequence is carried across the rebuild**, in both directions.
  `DROP TABLE` resets it even with foreign keys on, and the rows are gone but their ids
  are not forgotten everywhere: `feedback` survives the wipe, and its `page_path` can
  name `/groups/12/results`, which `/admin/feedback` renders as a link. Restarting at 1
  would point that link at an unrelated new group.

  The `CREATE TABLE` is `.schema activity_groups` of a freshly migrated database, column
  for column and in the same order, with exactly three changes: `organizer_id` loses
  `NOT NULL`, `anonymous_organizer_id` is added, and the CHECK. Foreign keys are written
  as **column-level `REFERENCES`**, never a table-level `FOREIGN KEY`: the older `down`s
  that `test/consensus/release_test.exs` replays drop `resolved_activity_id`,
  `search_area` and `search_bbox` with `DROP COLUMN`, which SQLite refuses for a column
  named in a table-level `FOREIGN KEY` or in a CHECK. The CHECK names only the two owner
  columns, which no older `down` drops.

    * `organizer_id ... ON DELETE CASCADE` is kept — `Accounts.delete_user/2` relies on
      it to take a deleted organizer's groups with them (invariant 5); without it the
      CHECK would make that delete fail instead.
    * `anonymous_organizer_id ... ON DELETE RESTRICT` — nothing but the boot sweep ever
      deletes an `anonymous_organizers` row, and only one that owns nothing. A wrong
      sweep predicate should raise, not cascade through groups and votes.

  `down/0` is the same wipe in reverse and is kept working, because `release_test.exs`
  rolls the whole chain back and CI's "Boot twice on one volume" step rolls this one
  back on a populated volume: delete every group, drop the table, recreate the
  pre-D-058 DDL (`organizer_id NOT NULL`, no `anonymous_organizer_id`, no CHECK) with
  its original index names, and only then drop `anonymous_organizers`. Rows do not
  survive a rollback any more than they survive the migration.
  """

  def up do
    create table(:anonymous_organizers) do
      add :token_hash, :binary, null: false
      # Nullable: what a guest sees instead of a username. Blank means "the organizer".
      add :display_name, :string
      add :claimed_by_user_id, references(:users, on_delete: :nilify_all)
      add :claimed_at, :utc_datetime
      add :last_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:anonymous_organizers, [:token_hash])
    create index(:anonymous_organizers, [:claimed_by_user_id])

    wipe_and_drop_activity_groups()

    execute("""
    CREATE TABLE "activity_groups" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "title" TEXT NOT NULL,
      "slug" TEXT NOT NULL,
      "status" TEXT DEFAULT 'draft' NOT NULL,
      "activity_type" TEXT DEFAULT 'restaurant' NOT NULL,
      "deadline_at" TEXT,
      "anonymous" INTEGER DEFAULT true NOT NULL,
      "veto_allowed" INTEGER DEFAULT true NOT NULL,
      "expected_voter_count" INTEGER,
      "completed_at" TEXT,
      "cancelled_at" TEXT,
      "organizer_id" INTEGER CONSTRAINT "activity_groups_organizer_id_fkey"
        REFERENCES "users"("id") ON DELETE CASCADE,
      "anonymous_organizer_id" INTEGER CONSTRAINT "activity_groups_anonymous_organizer_id_fkey"
        REFERENCES "anonymous_organizers"("id") ON DELETE RESTRICT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "resolution" TEXT,
      "resolved_activity_id" INTEGER CONSTRAINT "activity_groups_resolved_activity_id_fkey"
        REFERENCES "activities"("id") ON DELETE SET NULL,
      "resolved_at" TEXT,
      "search_area" TEXT,
      "search_bbox" TEXT,
      CONSTRAINT "organizer_xor_anonymous_organizer"
        CHECK (("organizer_id" IS NULL) <> ("anonymous_organizer_id" IS NULL))
    )
    """)

    restore_activity_groups_sequence()
    create_original_indexes()
    create index(:activity_groups, [:anonymous_organizer_id])
  end

  def down do
    wipe_and_drop_activity_groups()

    # The pre-D-058 table exactly as `.schema activity_groups` printed it after
    # `20260811172739_add_search_area_to_activity_groups` — what the previous release
    # boots against, and what the older `down`s in the chain expect to find.
    execute("""
    CREATE TABLE "activity_groups" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "title" TEXT NOT NULL,
      "slug" TEXT NOT NULL,
      "status" TEXT DEFAULT 'draft' NOT NULL,
      "activity_type" TEXT DEFAULT 'restaurant' NOT NULL,
      "deadline_at" TEXT,
      "anonymous" INTEGER DEFAULT true NOT NULL,
      "veto_allowed" INTEGER DEFAULT true NOT NULL,
      "expected_voter_count" INTEGER,
      "completed_at" TEXT,
      "cancelled_at" TEXT,
      "organizer_id" INTEGER NOT NULL CONSTRAINT "activity_groups_organizer_id_fkey"
        REFERENCES "users"("id") ON DELETE CASCADE,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "resolution" TEXT,
      "resolved_activity_id" INTEGER CONSTRAINT "activity_groups_resolved_activity_id_fkey"
        REFERENCES "activities"("id") ON DELETE SET NULL,
      "resolved_at" TEXT,
      "search_area" TEXT,
      "search_bbox" TEXT
    )
    """)

    restore_activity_groups_sequence()
    create_original_indexes()

    drop index(:anonymous_organizers, [:claimed_by_user_id])
    drop index(:anonymous_organizers, [:token_hash])
    drop table(:anonymous_organizers)
  end

  # Foreign keys are on (ecto_sqlite3's default), so the DELETE cascades to
  # `activities` and `participants`, and from both to `votes`; the circular
  # `resolved_activity_id → activities` is `SET NULL` on rows already being deleted. The
  # child tables are empty by the time `DROP TABLE` runs, so its own implicit delete has
  # nothing to violate. See the moduledoc for why this must not be `PRAGMA
  # foreign_keys = OFF` instead.
  #
  # The `AUTOINCREMENT` high-water mark is set aside first: `DROP TABLE` deletes the
  # table's `sqlite_sequence` row, and `restore_activity_groups_sequence/0` puts it back
  # once the new table exists. A temp table is per-connection and inside the same DDL
  # transaction, so a failed boot leaves nothing behind.
  defp wipe_and_drop_activity_groups do
    execute(~s(DELETE FROM "activity_groups"))

    execute("""
    CREATE TEMP TABLE "d058_activity_groups_seq" AS
      SELECT "seq" FROM "sqlite_sequence" WHERE "name" = 'activity_groups'
    """)

    execute(~s(DROP TABLE "activity_groups"))
  end

  # Without this, the first group after the deploy would be id 1 again — and a feedback
  # row that survived the wipe still names `/groups/1/results` in `page_path`, which
  # `/admin/feedback` renders as a link to whichever new group took that id. Group ids
  # are never reused, in either direction.
  defp restore_activity_groups_sequence do
    execute("""
    INSERT INTO "sqlite_sequence" ("name", "seq")
      SELECT 'activity_groups', "seq" FROM "d058_activity_groups_seq"
    """)

    execute(~s(DROP TABLE "d058_activity_groups_seq"))
  end

  # By their existing names — the DSL's defaults are exactly the names
  # `create_activity_groups` and `add_group_resolution` gave them, and the older
  # `down`s drop them by those names.
  defp create_original_indexes do
    create unique_index(:activity_groups, [:slug])
    create index(:activity_groups, [:organizer_id])
    create index(:activity_groups, [:resolved_activity_id])
  end
end
