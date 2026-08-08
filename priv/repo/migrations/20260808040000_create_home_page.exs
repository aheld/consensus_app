defmodule Consensus.Repo.Migrations.CreateHomePage do
  use Ecto.Migration

  @moduledoc """
  The home page message is a singleton row.

  `CHECK (id = 1)` makes "there is exactly one home page" a database invariant rather
  than an application convention, so no migration, seed or console session can insert
  a second one. SQLite only accepts CHECK constraints inside `CREATE TABLE` — it
  rejects `ALTER TABLE ... ADD CONSTRAINT`, and `Ecto.Migration.constraint/3` compiles
  to exactly that — so the table is created with literal SQL. Column types follow the
  ones ecto_sqlite3 generates (INTEGER ids, TEXT timestamps).
  """

  def change do
    execute(
      """
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
      """,
      """
      DROP TABLE "home_page"
      """
    )

    create index(:home_page, [:updated_by_id])
  end
end
