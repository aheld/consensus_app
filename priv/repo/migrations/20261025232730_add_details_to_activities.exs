defmodule Consensus.Repo.Migrations.AddDetailsToActivities do
  use Ecto.Migration

  @moduledoc """
  An option's details (D-060; docs/plans/item-details-and-catalog.md §1.3, §2): what
  the `05` winner card needs to be an action rather than a summary — call it, get
  directions, open its site. The website is the existing `source_url`; this adds the
  rest.

    * `phone` — as typed (or as the provider gave it); rendered as a `tel:` link built
      from `+` and digits only.
    * `address` — one human line ("237 Saint James Place, Philadelphia"). Not
      structured: one reader, one writer, nothing queries by street.
    * `latitude` / `longitude` — both or neither (the changeset's rule, not a CHECK).
    * `category` — generic on purpose: "israeli" for a restaurant, "bowling alley"
      for bowling. What the UI calls it is registry data (invariant 12).
    * `osm_ref` — `"node/6374481270"` when the details came from OpenStreetMap, so the
      ODbL credit can follow the data. Displayed never.

  This reverses D-052 §4's URL-only retention boundary: the firewall moves from "no
  column to put it in" to each provider's `retained_fields/0`.

  Plain nullable `ALTER TABLE ADD COLUMN`s, no defaults, no backfill — existing rows
  have no details, which is the truth. Safe against a populated table without a
  rebuild (the sqlite skill). `catalog_item_id` arrives with the catalog's own
  migration, since it references a table that does not exist yet.
  """

  def change do
    alter table(:activities) do
      add :phone, :string
      add :address, :string
      add :latitude, :float
      add :longitude, :float
      add :category, :string
      add :osm_ref, :string
    end
  end
end
