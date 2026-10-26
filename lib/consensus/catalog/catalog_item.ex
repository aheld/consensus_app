defmodule Consensus.Catalog.CatalogItem do
  @moduledoc """
  One entry in the shared catalog (D-060): an option an organizer chose to **Let
  anyone find this**, searched by the Assisted Add before Nominatim.

  A snapshot, not a live reference (docs/plans/item-details-and-catalog.md §3.2). The
  row's own fields mirror an `Activity`'s name, description, photo and details, plus:

    * `activity_type` — the registry key it is searched under. Data, filtered with a
      keyword `where/2`, never compared or branched on (invariant 12).
    * `search_name` — `Consensus.Catalog.search_name/1` of `name`, kept in step by
      every changeset here, so stored names and queries normalise identically.
    * `status` — `"visible"` or `"hidden"` (an admin's hide; the row stays, the search
      skips it).
    * `osm_ref` — the OSM element the details came from, when they did. Unique per
      type, the first deduplication key, and what decides whether the ODbL credit is
      owed wherever this row's details render.
    * `admin_edited_at` — set by an admin edit; from then on the sharing organizer's
      edits stop syncing (§3.2).

  `share_changeset/2` is for `Consensus.Catalog`'s organizer-side writes and
  `admin_changeset/2` for `/admin/items`; neither casts the provenance, the status or
  the use count, which the context sets programmatically.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Consensus.Activities.Activity

  @statuses ~w(visible hidden)
  @snapshot_fields [
    :name,
    :description,
    :image_url,
    :source_url,
    :phone,
    :address,
    :latitude,
    :longitude,
    :category,
    :osm_ref
  ]

  @doc "The fields a share copies from an `Activity` (and a use copies back)."
  def snapshot_fields, do: @snapshot_fields

  @doc "Every status a row may have."
  def statuses, do: @statuses

  schema "catalog_items" do
    field :activity_type, :string
    field :name, :string
    field :search_name, :string
    field :description, :string
    field :image_url, :string
    field :source_url, :string
    field :phone, :string
    field :address, :string
    field :latitude, :float
    field :longitude, :float
    field :category, :string
    field :osm_ref, :string
    field :status, :string, default: "visible"
    field :admin_edited_at, :utc_datetime
    field :use_count, :integer, default: 0

    belongs_to :shared_from_activity, Activity
    belongs_to :shared_by_user, Consensus.Accounts.User
    belongs_to :shared_by_anonymous_organizer, Consensus.Activities.AnonymousOrganizer

    timestamps(type: :utc_datetime)
  end

  @doc """
  An organizer's share or sync: the snapshot fields from their option. The type is
  cast only on insert (a row never moves between types).
  """
  def share_changeset(item, attrs) do
    item
    |> cast(attrs, [:activity_type | @snapshot_fields])
    |> validate_required([:activity_type])
    |> validate_snapshot()
  end

  @doc """
  An admin's edit on `/admin/items`: every snapshot field, raw coordinates included.
  `Consensus.Catalog.admin_update/3` stamps `admin_edited_at`.
  """
  def admin_changeset(item, attrs) do
    item
    |> cast(attrs, @snapshot_fields)
    |> validate_snapshot()
  end

  @doc "Hide or unhide (`/admin/items`)."
  def status_changeset(item, status) do
    item
    |> change(status: status)
    |> validate_inclusion(:status, @statuses)
  end

  # The same limits an option has, by reusing the option's own changesets on a
  # throwaway struct: one set of rules, so a row can never hold what an option could
  # not, and the two cannot drift.
  defp validate_snapshot(changeset) do
    changeset =
      changeset
      |> validate_required([:name])
      |> put_search_name()
      |> unique_constraint([:activity_type, :osm_ref],
        name: :catalog_items_activity_type_osm_ref_index
      )

    # Seeded with the row's current name: `Activity.changeset/2` requires one, and a
    # sync that does not touch the name must not read as a blank.
    probe =
      %Activity{name: get_field(changeset, :name)}
      |> Activity.changeset(Map.take(changeset.changes, [:name, :description, :image_url]))
      |> Activity.details_changeset(Map.take(changeset.changes, Activity.detail_fields()))

    Enum.reduce(probe.errors, changeset, fn {field, {message, opts}}, acc ->
      add_error(acc, field, message, opts)
    end)
  end

  defp put_search_name(changeset) do
    case get_change(changeset, :name) do
      name when is_binary(name) ->
        put_change(changeset, :search_name, Consensus.Catalog.search_name(name))

      _unchanged ->
        changeset
    end
  end
end
