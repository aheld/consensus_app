defmodule Consensus.Discovery.Result do
  @moduledoc """
  One transient search result from a `Consensus.Discovery.Provider`. Accepting a
  result (**Use this**) writes an ordinary `Consensus.Activities.Activity` from
  `persistable_attrs/1`; everything else here dies with the socket that displayed it.

  ## The retention firewall (D-060, reversing D-052 §4)

  D-052 §4 made it impossible to store a provider's forbidden fields by giving the
  schema nowhere to put them. Once every commercial provider had been rejected on its
  terms and the only live source was OSM (ODbL: storage permitted, attribution
  required), the guarantee moved into data. Each provider declares which fields may be
  persisted, `c:Consensus.Discovery.Provider.retained_fields/0`, and
  `Consensus.Discovery` stamps that list onto every result as `:retainable`.
  `persistable_attrs/1` is **the only code that turns a result into attrs, and it
  reads nothing outside `:retainable`**. A provider whose terms forbid a field omits
  it: the field is still displayed, and never stored. `Consensus.Discovery.Cache`
  refuses at boot a provider that declares a field outside `retainable_fields/0`.

  There is no `rating` or `price` field, and there never will be: those are
  licence-poisoned everywhere (docs/research/activity-discovery.md §3).

  ## Fields

    * `:name` — the canonical name. Becomes `Activity.name` on accept.
    * `:website_url` — becomes `Activity.source_url`; `Consensus.LinkPreview` then
      fills photo/description exactly as it does for a pasted link. May be `nil`.
    * `:phone`, `:latitude`, `:longitude`, `:category` — the matching
      `Activity` details. Adapters hand over only values `Activity.details_changeset/2`
      would accept (`Activity.valid_phone?/1`), so a bad tag drops a detail rather than
      failing the organizer's **Use this**.
    * `:address` — the short street line the suggestion row shows, the disambiguator
      between up to three matches (the assisted-add brief §4). Display-only.
    * `:full_address` — street plus locality; what is stored as `Activity.address`.
    * `:source` — an atom naming where this came from (e.g. `:osm`). For
      attribution, not for branching.
    * `:external_ref` — opaque provider ref (e.g. `"node/1234567"`). Displayed never.
    * `:osm_ref` — the OpenStreetMap element this result's data came from, or `nil`.
      Persisted as provenance (it is how the ODbL credit follows the data), whatever
      `:retainable` says: it is the attribution obligation, not provider data to keep.
    * `:description`, `:image_url` — only a catalog row carries these (an organizer
      shared them, D-060 Q6); Nominatim never sets them.
    * `:catalog_item_id` — the shared-catalog row this result is, or `nil`. Persisted
      as provenance, like `:osm_ref`: it is the link `Consensus.Catalog` counts uses by.
    * `:attribution` — the credit this one result owes, `%{prefix:, text:, url:}` or
      `nil`. An adapter may set it per result (a catalog row whose details came from
      OSM); otherwise `Consensus.Discovery` stamps its provider's `attribution/0`.
    * `:retainable` — set by `Consensus.Discovery`, never by an adapter: the fields
      this result's provider lets us persist. Defaults to `[]` (keep nothing).
  """

  @retainable_fields [
    :name,
    :website_url,
    :phone,
    :address,
    :latitude,
    :longitude,
    :category,
    :description,
    :image_url
  ]

  # Result field => Activity field. `:address` stores the full line, not the short one.
  @activity_fields %{
    name: :name,
    website_url: :source_url,
    phone: :phone,
    address: :address,
    latitude: :latitude,
    longitude: :longitude,
    category: :category,
    description: :description,
    image_url: :image_url
  }

  @enforce_keys [:name, :source]
  defstruct [
    :name,
    :website_url,
    :source,
    :external_ref,
    :osm_ref,
    :address,
    :full_address,
    :phone,
    :latitude,
    :longitude,
    :category,
    :description,
    :image_url,
    :catalog_item_id,
    :attribution,
    retainable: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          website_url: String.t() | nil,
          source: atom(),
          external_ref: String.t() | nil,
          osm_ref: String.t() | nil,
          address: String.t() | nil,
          full_address: String.t() | nil,
          phone: String.t() | nil,
          latitude: float() | nil,
          longitude: float() | nil,
          category: String.t() | nil,
          description: String.t() | nil,
          image_url: String.t() | nil,
          catalog_item_id: pos_integer() | nil,
          attribution: %{prefix: String.t(), text: String.t(), url: String.t()} | nil,
          retainable: [atom()]
        }

  @doc "Every field a provider may declare in `retained_fields/0`."
  @spec retainable_fields() :: [atom()]
  def retainable_fields, do: @retainable_fields

  @doc """
  The `Activity` attrs this result may write: one entry per field in `:retainable`
  that has a value, keyed by the `Activity` field (`:website_url` → `:source_url`,
  `:address` → the stored `:full_address`), plus the `:osm_ref` and `:catalog_item_id`
  provenance when set. Latitude and
  longitude travel together or not at all. Nothing outside `:retainable` is read.
  """
  @spec persistable_attrs(t()) :: map()
  def persistable_attrs(%__MODULE__{retainable: retainable} = result) when is_list(retainable) do
    @retainable_fields
    |> Enum.filter(&(&1 in retainable))
    |> Enum.map(&{Map.fetch!(@activity_fields, &1), stored_value(result, &1)})
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
    |> pair_coordinates()
    |> put_provenance(:osm_ref, result.osm_ref)
    |> put_provenance(:catalog_item_id, result.catalog_item_id)
  end

  defp stored_value(%__MODULE__{full_address: full}, :address), do: full
  defp stored_value(%__MODULE__{} = result, field), do: Map.fetch!(result, field)

  defp pair_coordinates(%{latitude: _, longitude: _} = attrs), do: attrs
  defp pair_coordinates(attrs), do: Map.drop(attrs, [:latitude, :longitude])

  defp put_provenance(attrs, _key, nil), do: attrs
  defp put_provenance(attrs, key, value), do: Map.put(attrs, key, value)
end
