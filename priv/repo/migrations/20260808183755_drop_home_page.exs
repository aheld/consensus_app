defmodule Consensus.Repo.Migrations.DropHomePage do
  use Ecto.Migration

  @moduledoc """
  Drops the admin-editable home-page message (D-027).

  `/` is now the product — the signed-out splash and the signed-in list of activity
  groups — so a single row of admin-authored prose has nowhere left to render. The table
  is dropped rather than left orphaned: an unused table with a foreign key into `users`
  is a live constraint on `Accounts.delete_user/2` for no benefit.

  `down/0` recreates the table so a rollback lands on a schema the previous release can
  boot against. It does **not** restore the row's contents — there is no copy of them to
  restore from; the default message went with the code.

  The recreation is literal SQL, mirroring `20260808040000_create_home_page.exs`, for the
  same reason that one gives: SQLite accepts a CHECK constraint only inside `CREATE TABLE`,
  and `Ecto.Migration.constraint/3` compiles to `ALTER TABLE … ADD CONSTRAINT`, which
  ecto_sqlite3 refuses outright. Writing this `down/0` with `create constraint(...)` looked
  correct, compiled, and blew up only under `Release.rollback(TmpRepo, 0)` — which is
  exactly the moment an operator needs it to work. `test/consensus/release_test.exs` rolls
  the whole schema down and is what catches it.
  """

  def up do
    drop index(:home_page, [:updated_by_id])
    drop table(:home_page)
  end

  def down do
    execute("""
    CREATE TABLE "home_page" (
      "id" INTEGER PRIMARY KEY
        CONSTRAINT "home_page_is_a_singleton" CHECK ("id" = 1),
      "message" TEXT NOT NULL,
      "updated_by_id" INTEGER
        CONSTRAINT "home_page_updated_by_id_fkey"
        REFERENCES "users"("id") ON DELETE SET NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """)

    create index(:home_page, [:updated_by_id])
  end
end
