defmodule Consensus.Repo.Migrations.CreateVotingTables do
  use Ecto.Migration

  @moduledoc """
  Participants (one person in one group's vote) and their votes.

  Like `create_activity_groups`, this uses the ordinary migration DSL rather than
  literal SQL: nothing here needs a `CREATE TABLE`-level CHECK, which is the only
  thing SQLite forces out of the DSL (`ALTER TABLE ADD CONSTRAINT` is unsupported).
  `kind` is a plain `:string` column on both tables, read through `Ecto.Enum` in the
  schemas — the same shape `activity_groups.status` uses.

  `participants.voted_at` is the ballot lock: non-nil means this participant has
  submitted and may not submit again. It is nullable by definition, and
  `Consensus.Voting.cast_ballot/3` stamps it with a conditional `UPDATE ... WHERE
  voted_at IS NULL` inside the same transaction that writes the vote rows, so two
  tabs double-submitting produce exactly one ballot.

  The unique index on `(group_id, user_id)` is **partial** (`WHERE user_id IS NOT
  NULL`). SQLite already treats NULLs as distinct in a unique index, so the partial
  clause is not strictly required to let many guests share a group — it is written
  out because the intent ("a signed-in user joins a group once") should be legible
  from the schema rather than inferred from NULL semantics.
  """

  def change do
    create table(:participants) do
      add :group_id, references(:activity_groups, on_delete: :delete_all), null: false
      add :display_name, :string
      add :kind, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :token, :string, null: false
      add :voted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:participants, [:token])
    create index(:participants, [:group_id])
    create unique_index(:participants, [:group_id, :user_id], where: "user_id IS NOT NULL")

    create table(:votes) do
      add :participant_id, references(:participants, on_delete: :delete_all), null: false
      add :activity_id, references(:activities, on_delete: :delete_all), null: false
      add :kind, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:votes, [:participant_id, :activity_id])
    create index(:votes, [:activity_id])
  end
end
