defmodule Consensus.Repo.Migrations.CreateActivityGroups do
  use Ecto.Migration

  @moduledoc """
  Activity groups (a titled, deadlined pool of options) and the activities inside them.

  Both tables use the ordinary Ecto migration DSL rather than literal SQL — unlike
  `create_home_page`, nothing here needs a `CREATE TABLE`-level CHECK, so there is no
  reason to hand-write DDL. `status` is stored as `:string` and validated at the
  `Ecto.Enum` layer in `Consensus.Activities.Group`, the same way `activity_type` is
  plain data (see CLAUDE.md product invariant 2 — the engine must stay
  activity-agnostic, so this column is never branched on in code).

  `activities.position` is deliberately **not** covered by a unique index on
  `(group_id, position)`. SQLite checks constraints immediately (there is no deferred
  mode), so renumbering positions after a delete or a full reorder would have to shuffle
  through a temporary collision on every write. Contiguity is instead an invariant the
  `Consensus.Activities` context maintains — see `delete_activity/2` and
  `reorder_activities/3`, both single-transaction.
  """

  def change do
    create table(:activity_groups) do
      add :title, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :activity_type, :string, null: false, default: "restaurant"
      add :deadline_at, :utc_datetime
      add :anonymous, :boolean, null: false, default: true
      add :veto_allowed, :boolean, null: false, default: true
      add :expected_voter_count, :integer
      add :completed_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :organizer_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:activity_groups, [:slug])
    create index(:activity_groups, [:organizer_id])

    create table(:activities) do
      add :group_id, references(:activity_groups, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :name, :string, null: false
      add :description, :string
      add :image_url, :string
      add :source_url, :string
      add :metadata_fetched_at, :utc_datetime
      add :added_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:activities, [:group_id])
    create index(:activities, [:added_by_id])
  end
end
