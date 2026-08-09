defmodule Consensus.Repo.Migrations.CreateFeedback do
  use Ecto.Migration

  @moduledoc """
  One table for what the two faces in the global footer collect (D-042).

  Shaped like `create_voting_tables`: the ordinary migration DSL, `:string` columns
  read back through `Ecto.Enum` in the schema rather than a database `CHECK` (SQLite
  only accepts those inside `CREATE TABLE`), and `timestamps(type: :utc_datetime)`.

  Two nullable columns carry state rather than a boolean, the way
  `participants.voted_at` does:

    * `read_at` — `NULL` means an admin has not triaged this yet. `/admin/feedback`
      can therefore un-mark a row by writing `NULL` back, which is the whole point:
      a one-way toggle on a triage list is a trap.
    * `page_path` — `NULL` means the sender left "include the screen I was on"
      unticked, or arrived at `/feedback` with no origin to include. It holds a local
      path and nothing else; there is deliberately no user agent, no IP and no
      referrer column, because the checkbox does not describe those.

  `user_id` is `on_delete: :nilify_all` rather than `:delete_all`: deleting an
  account through `/admin/users` must not destroy the bug report that account filed.
  There is deliberately **no** `group_id` reference. The session a sender was looking
  at is recorded as a path string, so a report survives its group being deleted and
  the `activity_groups` cascade in CLAUDE.md invariant 5 does not grow a fourth level.
  """

  def change do
    create table(:feedback) do
      add :mood, :string, null: false
      add :message, :string, null: false
      add :name, :string
      add :email, :string
      add :page_path, :string
      add :user_id, references(:users, on_delete: :nilify_all)
      add :read_at, :utc_datetime
      add :admin_note, :string

      timestamps(type: :utc_datetime)
    end

    # The queue is "newest first, unread first"; both orderings read this.
    create index(:feedback, [:inserted_at])
    create index(:feedback, [:read_at])
  end
end
