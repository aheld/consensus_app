defmodule Consensus.Activities.Activity do
  @moduledoc """
  One option in an activity group's pool — e.g. one restaurant.

  `position` is 1-based and contiguous within its group. `Consensus.Activities` is
  responsible for keeping it that way (append at `max(position) + 1`, renumber on
  delete); this changeset only validates that a position is a plain positive integer,
  it does not — and cannot, from a single row — check contiguity.

  `image_url` and `source_url` are URL-referenced only: there is no upload path.
  `metadata_fetched_at` is set by the (future) link-paste flow when it actually filled
  fields from `source_url`; a typed name with no link leaves both nil.

  ## Details (D-060)

  `source_url` doubles as the option's **website**, and `phone`, `address`,
  `latitude`/`longitude` and `category` are its other details — filled by the Assisted
  Add's **Use this** or typed on `02b`. They have their own changeset,
  `details_changeset/2`, and `changeset/2` does not cast them: the two write paths stay
  separate for the same reason `position_changeset/2` is its own function, and
  because details stay editable after the vote opens while the name and description
  do not (`Consensus.Activities.update_activity_details/3`).

  `osm_ref` is provenance, not a detail: set only by `lookup_changeset/2` (a lookup
  result the organizer confirmed), never by a form, and displayed never. Its presence
  is what says the ODbL credit is owed wherever this option's details render.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_name_length 120
  @max_description_length 140
  @max_address_length 200
  @max_category_length 60
  @max_phone_length 32
  @min_phone_digits 7
  @coordinate_decimals 7

  @detail_fields [:source_url, :phone, :address, :latitude, :longitude, :category]

  @doc "Longest name an activity may have."
  def max_name_length, do: @max_name_length

  @doc "Longest description an activity may have — the design's `62/140` counter."
  def max_description_length, do: @max_description_length

  @doc "Longest address an activity may have, in graphemes."
  def max_address_length, do: @max_address_length

  @doc "Longest category (cuisine, kind) an activity may have, in graphemes."
  def max_category_length, do: @max_category_length

  @doc "The fields `details_changeset/2` casts — an option's details, website included."
  def detail_fields, do: @detail_fields

  schema "activities" do
    field :position, :integer
    field :name, :string
    field :description, :string
    field :image_url, :string
    field :source_url, :string
    field :metadata_fetched_at, :utc_datetime
    field :phone, :string
    field :address, :string
    field :latitude, :float
    field :longitude, :float
    field :category, :string
    field :osm_ref, :string
    # The shared catalog (D-060): the row this option is linked to, and whether its
    # organizer has "Let anyone find this" on. Set only by `Consensus.Catalog`.
    field :shared_to_catalog_at, :utc_datetime
    belongs_to :catalog_item, Consensus.Catalog.CatalogItem

    belongs_to :group, Consensus.Activities.Group
    belongs_to :added_by, Consensus.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing an activity.

  `:group_id`, `:added_by_id` and `:position` are set programmatically by
  `Consensus.Activities` (from the scope, the parent group, and the current pool size
  respectively) and are deliberately absent from `cast/3`.
  """
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:name, :description, :image_url, :source_url, :metadata_fetched_at])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_length(:description, max: @max_description_length)
    |> validate_url(:image_url)
    |> validate_url(:source_url)
  end

  @doc """
  Changeset for setting an activity's position.

  Kept separate from `changeset/2` because reordering and renumbering never touch any
  other field, and because a public form must never be able to smuggle a position
  change through `attrs`.
  """
  def position_changeset(activity, position) when is_integer(position) do
    cast(activity, %{position: position}, [:position])
    |> validate_required([:position])
    |> validate_number(:position, greater_than: 0)
  end

  @doc """
  Changeset for an option's details: exactly `detail_fields/0`.

  Never the name, description or image (`changeset/2` owns those, and they freeze when
  the vote opens), and never `osm_ref` (`lookup_changeset/2`). Blank strings become
  `nil` (Ecto's `empty_values`), so clearing a field on `02b` removes the detail.

    * `phone` — at most #{@max_phone_length} characters of digits, spaces and
      `+ ( ) - .`, with at least #{@min_phone_digits} digits. Stored as typed;
      `tel_href/1` is what reaches an `href`.
    * `address` / `category` — grapheme caps (#{@max_address_length} /
      #{@max_category_length}), enforced here and nowhere in the template (invariant
      11: no `maxlength`).
    * `latitude` / `longitude` — both or neither, in range, rounded to
      #{@coordinate_decimals} decimals (OSM's own precision).
  """
  def details_changeset(activity, attrs) do
    activity
    |> cast(attrs, @detail_fields)
    |> update_change(:phone, &trim/1)
    |> update_change(:address, &trim/1)
    |> update_change(:category, &trim/1)
    |> validate_url(:source_url)
    |> validate_phone()
    |> validate_length(:address, max: @max_address_length)
    |> validate_length(:category, max: @max_category_length)
    |> validate_coordinates()
  end

  @doc """
  Changeset for adopting a lookup result the organizer confirmed with **Use this**:
  the name — and, from a shared-catalog row, the description and photo — (via
  `changeset/2`), the details (via `details_changeset/2`) and the `osm_ref` /
  `catalog_item_id` provenance, in one write. `attrs` come from
  `Consensus.Discovery.Result.persistable_attrs/1`, which is the retention firewall —
  this changeset trusts it to have dropped every field the provider may not let us
  keep.
  """
  def lookup_changeset(activity, attrs) do
    activity
    |> changeset(Map.take(attrs, [:name, :description, :image_url]))
    |> details_changeset(Map.take(attrs, @detail_fields))
    |> cast(attrs, [:osm_ref, :catalog_item_id])
  end

  @doc """
  Whether `value` is a phone number `details_changeset/2` accepts. Public because the
  lookup adapters filter provider-supplied numbers through the same rule, so a bad
  OSM tag is dropped instead of failing the organizer's **Use this**.
  """
  def valid_phone?(value) when is_binary(value) do
    value = String.trim(value)

    String.length(value) <= @max_phone_length and
      Regex.match?(~r/\A[0-9 +().\-]+\z/, value) and
      digit_count(value) >= @min_phone_digits
  end

  def valid_phone?(_value), do: false

  @doc """
  The `tel:` URL for a stored phone, built from `+` and digits only — so stored text
  never reaches an `href` raw. `nil` for a blank or missing phone.
  """
  def tel_href(phone) when is_binary(phone) do
    case String.replace(phone, ~r/[^0-9+]/, "") do
      "" -> nil
      dialable -> "tel:" <> dialable
    end
  end

  def tel_href(_phone), do: nil

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp digit_count(value), do: value |> String.replace(~r/[^0-9]/, "") |> String.length()

  defp validate_phone(changeset) do
    validate_change(changeset, :phone, fn :phone, value ->
      if valid_phone?(value),
        do: [],
        else: [phone: "must be a phone number (digits, spaces and + ( ) - .)"]
    end)
  end

  defp validate_coordinates(changeset) do
    changeset =
      changeset
      |> update_change(:latitude, &round_coordinate/1)
      |> update_change(:longitude, &round_coordinate/1)
      |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
      |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)

    case {get_field(changeset, :latitude), get_field(changeset, :longitude)} do
      {nil, nil} -> changeset
      {lat, lon} when is_float(lat) and is_float(lon) -> changeset
      {nil, _lon} -> add_error(changeset, :latitude, "must be set together with longitude")
      {_lat, nil} -> add_error(changeset, :longitude, "must be set together with latitude")
    end
  end

  defp round_coordinate(value) when is_float(value), do: Float.round(value, @coordinate_decimals)
  defp round_coordinate(value), do: value

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid http(s) URL"}]
      end
    end)
  end
end
