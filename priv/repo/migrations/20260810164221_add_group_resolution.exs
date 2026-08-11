defmodule Consensus.Repo.Migrations.AddGroupResolution do
  use Ecto.Migration

  @moduledoc """
  How a completed group's endgame was settled, when it could not settle itself.

  Three nullable columns on `activity_groups`, written only by
  `Consensus.Activities.resolve_group/4` (and cleared by `reopen_group/2`):

    * `resolution` — `"organizer_pick"` (tie: the organizer tapped a row and locked
      it), `"app_pick"` (tie: the app shuffled), or `"app_rescue"` (all-vetoed: the
      app picked one at random and its veto is undone in presentation). Validated at
      the `Consensus.Activities.Group` changeset layer, same shape as `status`.
    * `resolved_activity_id` — which option the resolution landed on.
      `on_delete: :nilify_all`, not `:delete_all`: the pool is frozen for any group
      that can carry a resolution (D-037), so this only fires under a cascade that is
      destroying the whole group anyway — but a dangling id must never keep a deleted
      activity's ghost in the tally.
    * `resolved_at` — when.

  **No vote rows are touched by resolution.** "Undo that option's veto" is an
  interpretation `Consensus.Voting.tally/1` applies when it sees `"app_rescue"`, not a
  data mutation — the votes stay true; only the reading of them is recorded here.

  Plain `ALTER TABLE ADD COLUMN`s, which SQLite supports: every column is nullable
  with a NULL default, which is also what the REFERENCES clause requires in an
  `ADD COLUMN`.
  """

  def change do
    alter table(:activity_groups) do
      add :resolution, :string
      add :resolved_activity_id, references(:activities, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
    end

    create index(:activity_groups, [:resolved_activity_id])
  end
end
