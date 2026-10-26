defmodule Consensus.Discovery.Provider.Nominatim do
  @moduledoc """
  The live `Consensus.Discovery.Provider`: lookup of a **named place** against
  Nominatim's POI search (OpenStreetMap data), through the one
  `Consensus.Discovery.Nominatim` client the geocoder also uses
  (docs/plans/nominatim-lookup.md, D-059).

  Lookup, not enumeration. Research trap F warns that Nominatim "declines to
  answer 'all objects of a type in an area'" — that is browsing every
  restaurant in a neighbourhood, the parked Discover screen. The assist asks
  for one name the organizer already typed, which is exactly what Nominatim is
  built for. Its other policy clauses are met where they belong: one request
  per second app-wide (the client's gate), results cached
  (`Consensus.Discovery`, per `cache_policy/0`), no autocomplete (one search
  per **Add** — `02 add options` has no `phx-change`), an identifying
  User-Agent (the client).

  One module serves every OSM-backed activity type. The per-type knowledge is
  the `categories: [{key, value}]` allowlist each registry entry carries (for
  example `{"leisure", "bowling_alley"}` or `{"amenity", "cinema"}`), which
  arrives in `opts`. Nothing here knows which type it is answering for, which
  is what keeps CLAUDE.md product invariant 2 checkable.

  ## The query

  One GET (`request_params/2`): the typed name as free text, `layer=poi`, the
  area's bbox as a `viewbox` with `bounded=1`, `limit=10`, plus
  `addressdetails` and `extratags` so one response carries the street address,
  website and cuisine. Nominatim does the fuzzy part — word order, `&` vs
  `and`, accents — that a literal name regex could not.

  The bbox is widened to at least `@min_span_deg` on each axis around its
  centre, at search time only: a neighbourhood that geocodes to a point comes
  back as a ±0.01° box, and a favourite place three blocks past the line would
  otherwise be out of bounds. The stored `search_bbox` is untouched.

  ## The category allowlist is applied to the answer

  Nominatim's free-text search cannot be filtered by tag in the query, so the
  categories are an allowlist over `category`/`type` in the response: ten
  results are asked for, the ones outside the list are dropped (and counted —
  the `filtered` field on the `provider_request` span's stop event answers
  "Nominatim found it, so why didn't I see it?"), and `Consensus.Discovery`
  caps the rest at 3.

  ## What comes back

  Only named elements survive. `website_url` is the first **valid** of the
  `website` | `contact:website` | `url` extratags, where valid includes the SSRF
  guard: OSM tags are crowd-edited, so a URL coming back from a provider is
  attacker-influenceable input (research trap J). Every candidate must be an
  absolute http(s) URL with a host *and* pass `Consensus.LinkPreview.check_host/1`
  — the same allowlist the paste path enforces, never a second one that
  drifts. An invalid URL nulls the field, never drops the result.

  The details (D-060) come from the same response: `phone` is the first of
  the `phone` | `contact:phone` extratags (each `;`-split) that passes
  `Consensus.Activities.Activity.valid_phone?/1`; `lat`/`lon` (strings in
  jsonv2) are parsed; `full_address` is the street line plus the locality. The
  `category` is the first value of the extratag the registry entry names in
  `category_tag:` (`"cuisine"` for dining) or, for an entry without one,
  Nominatim's own `type` humanised (`"bowling_alley"` → `"bowling alley"`).
  ODbL permits storing all of it, so `retained_fields/0` declares every
  retainable field. `display_name`, `importance`, `place_id` and the
  email/hours tags are still read past: nothing displays them.

  ## Errors

  `search/3` never raises. The client's tags (`t:Consensus.Discovery.Nominatim.error/0`)
  pass through unchanged. A gate refusal stays `:busy`, distinct from a 429's
  `:rate_limited`, because `Consensus.Discovery` never caches `:busy`: nothing
  was asked. Every failure renders as silence (D-052 §9); the tags exist for
  the log.
  """

  @behaviour Consensus.Discovery.Provider

  alias Consensus.Activities.Activity
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Nominatim
  alias Consensus.Discovery.Result
  alias Consensus.LinkPreview

  require Logger

  @ttl_ms :timer.hours(24)
  @error_ttl_ms :timer.minutes(1)
  @result_limit 10
  # ~4.4 km of latitude; a point-sized neighbourhood box is ±0.01° (~2 km).
  @min_span_deg 0.04

  @website_tags ["website", "contact:website", "url"]
  @phone_tags ["phone", "contact:phone"]
  @locality_keys ["city", "town", "village", "hamlet"]

  @impl true
  def search(query, area, opts)

  def search(query, %Area{bbox: bbox}, opts) when is_binary(query) and is_list(opts) do
    categories = Keyword.get(opts, :categories, [])
    category_tag = Keyword.get(opts, :category_tag)
    query = sanitize_query(query)

    # Both refusals answer with the brief's silence rather than a request: an
    # empty category list is a registry misconfiguration that would allow
    # nothing anyway, and a query that sanitises to "" has nothing to ask.
    if categories == [] or query == "" do
      {:ok, []}
    else
      safe_search(query, bbox, categories, category_tag)
    end
  end

  # location_mode/0 is :required: with no area there is nowhere to look, and
  # the brief's rule for every non-answer is silence, not an error.
  def search(_query, _area, _opts), do: {:ok, []}

  @impl true
  def cache_policy do
    %{ttl_ms: @ttl_ms, error_ttl_ms: @error_ttl_ms, may_store_results?: true}
  end

  @impl true
  def attribution do
    # The frame links ONLY the contributors phrase (the prefix stays plain text), and
    # the brief's constraint 3 + the frame both point the link at the ODbL licence —
    # not at osm.org/copyright.
    %{
      prefix: "Places from ",
      text: "OpenStreetMap contributors",
      url: "https://opendatacommons.org/licenses/odbl/"
    }
  end

  @impl true
  def location_mode, do: :required

  # ODbL: storage permitted, attribution required (research §4.1, trap I) — so every
  # field, with the attribution following the data through `osm_ref`.
  @impl true
  def retained_fields, do: Result.retainable_fields()

  @doc """
  The query parameters `search/3` sends for `query` inside `bbox`. Public so
  tests can pin them; not part of the `Consensus.Discovery.Provider` contract.
  """
  @spec request_params(String.t(), Area.bbox()) :: keyword()
  def request_params(query, bbox) do
    [
      q: query,
      format: "jsonv2",
      layer: "poi",
      viewbox: viewbox(bbox),
      bounded: 1,
      limit: @result_limit,
      addressdetails: 1,
      extratags: 1
    ]
  end

  @doc """
  `bbox` (`Area`'s `{min_lat, min_lon, max_lat, max_lon}`) as Nominatim's
  `viewbox` string, which is `left,top,right,bottom` — i.e.
  `min_lon,max_lat,max_lon,min_lat` — after widening each axis to at least
  #{@min_span_deg}°. The reordering lives here and nowhere else.
  """
  @spec viewbox(Area.bbox()) :: String.t()
  def viewbox(bbox) do
    {min_lat, min_lon, max_lat, max_lon} = widen_bbox(bbox)

    Enum.map_join([min_lon, max_lat, max_lon, min_lat], ",", &coord_to_string/1)
  end

  @doc """
  `bbox` with each axis widened to at least #{@min_span_deg}° around its centre — the
  search-time widening `viewbox/1` applies. Public so `Consensus.Catalog` decides
  "nearby" with exactly the same box the Nominatim lookup would have searched (D-060).
  """
  @spec widen_bbox(Area.bbox()) :: Area.bbox()
  def widen_bbox({min_lat, min_lon, max_lat, max_lon}) do
    {min_lat, max_lat} = widen(min_lat, max_lat)
    {min_lon, max_lon} = widen(min_lon, max_lon)
    {min_lat, min_lon, max_lat, max_lon}
  end

  defp widen(low, high) do
    if high - low < @min_span_deg do
      centre = (low + high) / 2
      {centre - @min_span_deg / 2, centre + @min_span_deg / 2}
    else
      {low, high}
    end
  end

  # Seven decimals is OSM's own precision, and it keeps float noise from the
  # widening (39.953255499999996) out of the URL and the cache key's repro line.
  defp coord_to_string(value) when is_integer(value), do: coord_to_string(value / 1)

  defp coord_to_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 7])

  ## The request

  defp safe_search(query, bbox, categories, category_tag) do
    perform_search(query, bbox, categories, category_tag)
  rescue
    exception ->
      Logger.error(
        "Consensus.Discovery.Provider.Nominatim: search for #{inspect(query)} raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :search_failed}
  end

  defp perform_search(query, bbox, categories, category_tag) do
    params = request_params(query, bbox)

    # The URL goes out on the span's :start, built by the client from the same
    # params that go on the wire (D-056 §4: the module that sends the request
    # builds the logged URL). The :stop carries the HTTP status separately from
    # Discovery's own timing, and how many answers the allowlist dropped.
    :telemetry.span(
      [:consensus, :discovery, :provider_request],
      %{
        provider: __MODULE__,
        url: Nominatim.request_url(params),
        bbox: bbox,
        categories: categories
      },
      fn ->
        {result, filtered} =
          case Nominatim.search(params) do
            {:ok, places} -> to_results(places, categories, category_tag)
            {:error, reason} -> {{:error, reason}, 0}
          end

        {result, request_stop_metadata(result, filtered)}
      end
    )
  end

  # span/3 does not merge start metadata into the stop event, so the status is
  # derived from the outcome rather than carried forward from the request.
  defp request_stop_metadata({:ok, results}, filtered),
    do: %{outcome: :ok, status: 200, count: length(results), filtered: filtered}

  defp request_stop_metadata({:error, :rate_limited}, _filtered),
    do: %{outcome: :error, status: 429, reason: :rate_limited}

  defp request_stop_metadata({:error, {:http, status}}, _filtered),
    do: %{outcome: :error, status: status, reason: {:http, status}}

  defp request_stop_metadata({:error, reason}, _filtered),
    do: %{outcome: :error, status: nil, reason: reason}

  ## Element → Result mapping

  defp to_results(places, categories, category_tag) do
    {allowed, dropped} = Enum.split_with(places, &allowed?(&1, categories))
    {{:ok, Enum.flat_map(allowed, &map_place(&1, category_tag))}, length(dropped)}
  end

  defp allowed?(%{"category" => key, "type" => value}, categories),
    do: {key, value} in categories

  defp allowed?(_place, _categories), do: false

  defp map_place(
         %{"osm_type" => osm_type, "osm_id" => osm_id, "name" => name} = place,
         category_tag
       )
       when osm_type in ["node", "way", "relation"] and is_integer(osm_id) and is_binary(name) do
    case String.trim(name) do
      "" ->
        []

      trimmed_name ->
        address = map_or_empty(place["address"])
        extratags = map_or_empty(place["extratags"])
        ref = "#{osm_type}/#{osm_id}"
        {latitude, longitude} = coordinates(place)
        street = address(address)

        [
          %Result{
            name: trimmed_name,
            website_url: website_url(extratags),
            source: :osm,
            external_ref: ref,
            osm_ref: ref,
            address: street,
            full_address: full_address(street, address),
            phone: phone(extratags),
            latitude: latitude,
            longitude: longitude,
            category: category(place, extratags, category_tag)
          }
        ]
    end
  end

  defp map_place(_place, _category_tag), do: []

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_other), do: %{}

  # First *valid* candidate wins — validity includes the SSRF allowlist (trap
  # J): absolute http(s) with a host, and the host passes the same
  # LinkPreview.check_host/1 the paste path runs. All invalid → nil, never a
  # dropped result.
  defp website_url(extratags) do
    @website_tags
    |> Enum.map(&Map.get(extratags, &1))
    |> Enum.find_value(&validate_website/1)
  end

  defp validate_website(value) when is_binary(value) do
    url = String.trim(value)

    with %URI{scheme: scheme, host: host}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.parse(url),
         :ok <- LinkPreview.check_host(host) do
      url
    else
      _ -> nil
    end
  end

  defp validate_website(_value), do: nil

  defp address(%{"house_number" => number, "road" => road})
       when is_binary(number) and is_binary(road) do
    case {String.trim(number), String.trim(road)} do
      {"", ""} -> nil
      {"", road} -> road
      {_number, ""} -> nil
      {number, road} -> "#{number} #{road}"
    end
  end

  defp address(%{"road" => road}) when is_binary(road) do
    case String.trim(road) do
      "" -> nil
      road -> road
    end
  end

  defp address(_address), do: nil

  # The street line plus the first locality Nominatim gives ("237 Saint James
  # Place, Philadelphia"). No street, no stored address: a bare city is not a
  # detail anyone can find a place by. Over the Activity cap → the street alone.
  defp full_address(nil, _address), do: nil

  defp full_address(street, address) do
    full =
      case Enum.find_value(@locality_keys, &non_blank(address[&1])) do
        nil -> street
        locality -> "#{street}, #{locality}"
      end

    if String.length(full) <= Activity.max_address_length(), do: full, else: street
  end

  # Phone tags are crowd-edited and often multivalued ("+1 215…;+1 267…"): the
  # first value that passes the same rule the changeset enforces, or nil.
  defp phone(extratags) do
    @phone_tags
    |> Enum.flat_map(fn tag ->
      case extratags[tag] do
        value when is_binary(value) -> String.split(value, ";")
        _other -> []
      end
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&Activity.valid_phone?/1)
  end

  # jsonv2 sends coordinates as strings. Both or neither, in range.
  defp coordinates(%{"lat" => lat, "lon" => lon}) do
    with {latitude, ""} when latitude >= -90 and latitude <= 90 <- parse_float(lat),
         {longitude, ""} when longitude >= -180 and longitude <= 180 <- parse_float(lon) do
      {latitude, longitude}
    else
      _ -> {nil, nil}
    end
  end

  defp coordinates(_place), do: {nil, nil}

  defp parse_float(value) when is_binary(value), do: Float.parse(String.trim(value))
  defp parse_float(value) when is_number(value), do: {value / 1, ""}
  defp parse_float(_value), do: :error

  # With a `category_tag` (registry data — "cuisine" for dining) the tag's first
  # `;`-separated value; without one, Nominatim's own `type`. Underscores humanised
  # either way, and nothing over the Activity cap.
  defp category(_place, extratags, tag) when is_binary(tag),
    do: humanise(first_value(extratags[tag]))

  defp category(place, _extratags, _tag), do: humanise(place["type"])

  defp first_value(value) when is_binary(value),
    do: value |> String.split(";", parts: 2) |> hd()

  defp first_value(_value), do: nil

  defp humanise(value) when is_binary(value) do
    value = value |> String.trim() |> String.replace("_", " ")

    if value == "" or String.length(value) > Activity.max_category_length(),
      do: nil,
      else: value
  end

  defp humanise(_value), do: nil

  defp non_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_blank(_value), do: nil

  ## Query hygiene

  # Control characters (a pasted newline, a smuggled NUL) have no place in a
  # name lookup — flattened to spaces. Invalid UTF-8 (attacker-influenceable,
  # straight from a paste) degrades to "", which search/3 already answers with
  # silence; the ~r/.../u regex would otherwise raise outside safe_search's
  # rescue.
  defp sanitize_query(query) do
    if String.valid?(query) do
      query
      |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
      |> String.trim()
    else
      ""
    end
  end
end
