defmodule Consensus.Repo.Migrations.CreateCatalogItems do
  use Ecto.Migration

  @moduledoc """
  The shared catalog (D-060; docs/plans/item-details-and-catalog.md §3): options an
  organizer chose to **Let anyone find this**, searched by the Assisted Add before
  Nominatim.

  A row is a **snapshot**, not a live reference: sharing copies an option's name and
  details here, and using a catalog result copies them back into another group's
  option. Every foreign key is `ON DELETE SET NULL` — a catalog row outlives the
  option, the account or the anonymous identity that shared it, losing only its
  provenance:

    * `shared_from_activity_id` — the option whose later edits this row follows (until
      an admin edits it, `admin_edited_at`).
    * `shared_by_user_id` / `shared_by_anonymous_organizer_id` — who shared it. The
      anonymous one matters because D-058's boot sweep deletes identities that own no
      *group*, and a catalog row is not a group.

  `activities` gains two columns:

    * `catalog_item_id` — the row this option is linked to (it shared into it, or it
      was filled from it), `ON DELETE SET NULL`: deleting a catalog row never touches
      a group's copy.
    * `shared_to_catalog_at` — set while this option's organizer has the toggle on.
      Separate from the link because an option filled *from* the catalog is linked but
      not shared (§3.2: "that group's later edits stay local unless that organizer
      shares too").

  Plain `ADD COLUMN`s on `activities` (nullable, no default, a `REFERENCES` clause
  SQLite accepts on ADD COLUMN because the default is NULL) — no rebuild.
  """

  def change do
    create table(:catalog_items) do
      add :activity_type, :string, null: false
      add :name, :string, null: false
      add :search_name, :string, null: false
      add :description, :string
      add :source_url, :string
      add :phone, :string
      add :address, :string
      add :latitude, :float
      add :longitude, :float
      add :category, :string
      add :image_url, :string
      add :osm_ref, :string
      add :status, :string, null: false, default: "visible"
      add :shared_from_activity_id, references(:activities, on_delete: :nilify_all)
      add :shared_by_user_id, references(:users, on_delete: :nilify_all)

      add :shared_by_anonymous_organizer_id,
          references(:anonymous_organizers, on_delete: :nilify_all)

      add :admin_edited_at, :utc_datetime
      add :use_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:catalog_items, [:activity_type, :osm_ref],
             where: "osm_ref IS NOT NULL",
             name: :catalog_items_activity_type_osm_ref_index
           )

    create index(:catalog_items, [:activity_type, :status, :search_name])
    create index(:catalog_items, [:shared_from_activity_id])

    alter table(:activities) do
      add :catalog_item_id, references(:catalog_items, on_delete: :nilify_all)
      add :shared_to_catalog_at, :utc_datetime
    end

    create index(:activities, [:catalog_item_id])
  end
end
