defmodule Consensus.Repo.Migrations.AddSearchAreaToActivityGroups do
  use Ecto.Migration

  @moduledoc """
  Storage for the Assisted Add area prompt (F2 of
  `docs/design/assisted-add-ux-brief.md`), stored on the group rather than the
  person — see `docs/research/activity-discovery.md` §4.1: the pool already names
  local restaurants to everyone with the share link, so a neighbourhood string is a
  property of the dinner, not the organizer.

  Two nullable columns on `activity_groups`, neither with a default:

    * `search_area` — the human-typed neighbourhood/city string the organizer
      answered the one-time area prompt with (e.g. `"Fishtown"`), before it is
      geocoded.
    * `search_bbox` — the geocoded bounding box, stored as a single string
      `"min_lat,min_lon,max_lat,max_lon"`. Parsed (and produced) by whatever reads
      it — there is no reader yet as of this migration; this storage-only change
      lands ahead of `Consensus.Discovery`/`Consensus.Discovery.Geocoder` per the
      research doc §4.1/§4.2. Kept as a single delimited string rather than four
      columns because Nominatim already returns a bbox as one `[south, north,
      west, east]`-shaped tuple and there is exactly one reader; four nullable
      floats would need their own "did the geocode ever run" sentinel that a
      single nullable string gets for free (`nil` = not yet geocoded).

  Plain `ALTER TABLE ADD COLUMN`s, which SQLite supports: both columns are
  nullable with no default, so this is safe against a populated table (see the
  sqlite skill's "Adding a NOT NULL column" trap — this migration deliberately
  does not fall into it).
  """

  def change do
    alter table(:activity_groups) do
      add :search_area, :string
      add :search_bbox, :string
    end
  end
end
