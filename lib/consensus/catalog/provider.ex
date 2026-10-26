defmodule Consensus.Catalog.Provider do
  @moduledoc """
  The shared catalog as a `Consensus.Discovery.Provider` (D-060 §3.4), registered
  **first** in each type's chain so a catalog hit answers before — and instead of — a
  Nominatim request:

      type => [
        {Consensus.Catalog.Provider, activity_type: type},
        {Consensus.Discovery.Provider.Nominatim, categories: [...], ...}
      ]

  The adapter never sees the type a search is for (no adapter does), so the registry
  entry hands it over as data in `opts` — `activity_type:` — and `Consensus.Catalog`
  filters on it with a keyword `where/2`. An entry without it answers `{:ok, []}`.

    * `cache_policy/0` is `ttl_ms: :none`: a local query needs no cache, and an admin's
      hide must take effect on the very next search.
    * `location_mode/0` is `:optional`: with no group area every visible row of the
      type is eligible.
    * `retained_fields/0` is everything: the rows are organizers' own entries, and the
      OSM-derived ones are ODbL, which permits storage.
    * `attribution/0` is `nil`, and each result carries its own instead: the OSM line
      for a row whose details came from OSM (an `osm_ref`), nothing for one an
      organizer typed. `Discovery.attribution_for_results/1` reads it.

  A query that raises is rescued here and answered `{:error, :search_failed}`, which
  `Consensus.Discovery` treats as a miss and falls through to Nominatim — the assist
  behaves exactly as it did before the catalog existed.
  """

  @behaviour Consensus.Discovery.Provider

  alias Consensus.Catalog
  alias Consensus.Catalog.CatalogItem
  alias Consensus.Discovery.Provider.Nominatim
  alias Consensus.Discovery.Result

  require Logger

  @impl true
  def search(query, area, opts) when is_binary(query) and is_list(opts) do
    type = Keyword.get(opts, :activity_type)

    if is_binary(type),
      do: {:ok, type |> Catalog.search(query, area) |> Enum.map(&to_result/1)},
      else: {:ok, []}
  rescue
    exception ->
      Logger.error("Consensus.Catalog.Provider: search raised " <> Exception.message(exception))
      {:error, :search_failed}
  end

  def search(_query, _area, _opts), do: {:ok, []}

  @impl true
  def cache_policy, do: %{ttl_ms: :none, error_ttl_ms: 1, may_store_results?: true}

  @impl true
  def attribution, do: nil

  @impl true
  def location_mode, do: :optional

  @impl true
  def retained_fields, do: Result.retainable_fields()

  defp to_result(%CatalogItem{} = row) do
    %Result{
      name: row.name,
      website_url: row.source_url,
      source: :catalog,
      external_ref: "catalog/#{row.id}",
      catalog_item_id: row.id,
      osm_ref: row.osm_ref,
      address: row.address,
      full_address: row.address,
      phone: row.phone,
      latitude: row.latitude,
      longitude: row.longitude,
      category: row.category,
      description: row.description,
      image_url: row.image_url,
      attribution: if(present?(row.osm_ref), do: Nominatim.attribution())
    }
  end

  defp present?(value), do: is_binary(value) and value != ""
end
