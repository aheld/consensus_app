defmodule Consensus.Discovery.Geocoder do
  @moduledoc """
  Turns a typed neighbourhood/city string into a `Consensus.Discovery.Area` via
  Nominatim — **submit-only**, per the area-prompt spec
  (docs/design/assisted-add-ux-brief.md F2) and Nominatim's usage policy, which
  forbids autocomplete outright (docs/research/activity-discovery.md trap F).
  Nothing here may ever be called per keystroke; one call per submitted form,
  and from `start_async/3`, never inline in a `handle_event` (CLAUDE.md
  invariant 13 — this is a network request with multi-second budgets).

  The request itself goes through `Consensus.Discovery.Nominatim`, the one
  client both Nominatim callers share: it owns the endpoint, the identifying
  User-Agent, the timeouts and the app-wide one-request-per-second gate.
  What stays here is the policy's other requirement, **caching**: successful
  geocodes are cached effectively indefinitely (`@success_ttl_ms`, one year) in
  `Consensus.Discovery.Cache` — a neighbourhood's bounding box is immutable at
  the resolution we use, and re-asking a volunteer service the same question is
  exactly what its policy exists to stop. Failures are cached briefly
  (`@error_ttl_ms`) so a transient outage heals without hammering the endpoint
  either. A gate refusal (`:busy`) is the one failure never cached: nothing was
  asked, so there is no answer to remember, and the organizer's next submit
  should really try.

  Every request carries `countrycodes` from
  `config :consensus, Consensus.Discovery.Geocoder, countrycodes:` (`"us"` by
  default; `nil` means no restriction). Without it a bare ZIP is a global
  question: `"19125"`, a Philadelphia ZIP, resolves to La Spezia, Italy, and
  that bbox would be stored on the group.

  `geocode/1` never raises: every failure is a tagged tuple, per
  `Consensus.LinkPreview.fetch/1`'s contract.
  """

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Cache
  alias Consensus.Discovery.Nominatim

  require Logger

  @success_ttl_ms :timer.hours(24 * 365)
  @error_ttl_ms :timer.minutes(5)

  @doc """
  Geocodes `area_string` (e.g. `"Fishtown, Philadelphia"`) into
  `{:ok, %Area{}}`.

  Returns:
    * `{:error, :invalid_area}` — blank or not a string. Checked before the
      cache and the network.
    * `{:error, :not_found}` — Nominatim answered cleanly with zero results.
    * `{:error, :geocode_failed}` — a non-200, a transport error, an
      unparseable body, or anything raised along the way. Never raises.

  The cache key is the trimmed, downcased string, so `" Fishtown "` and
  `"fishtown"` cost one request between them.
  """
  @spec geocode(String.t()) :: {:ok, Area.t()} | {:error, atom()}
  def geocode(area_string) when is_binary(area_string),
    do: cached_geocode(area_string, :geocode, &build_area/2)

  def geocode(_area_string), do: {:error, :invalid_area}

  @doc """
  Geocodes one option's typed address (`02b`'s **Find from address**, D-060) into
  `{:ok, {latitude, longitude}}` — the first result's point, not a bounding box.

  Same request, same gate, same cache (under its own `{:geocode_point, query}` key)
  and the same submit-only rule as `geocode/1`: one call per press, from
  `start_async/3`. Same error tags; never raises.
  """
  @spec geocode_point(String.t()) :: {:ok, {float(), float()}} | {:error, atom()}
  def geocode_point(address) when is_binary(address),
    do: cached_geocode(address, :geocode_point, &build_point/2)

  def geocode_point(_address), do: {:error, :invalid_area}

  defp cached_geocode(raw, kind, build) do
    case String.trim(raw) do
      "" ->
        {:error, :invalid_area}

      query ->
        cache_key = {kind, String.downcase(query)}

        # Spanned around the cache, not around the HTTP call: a success is
        # cached for ~a year, so the overwhelming majority of geocodes never
        # reach the network and an HTTP-level event would show nothing at all.
        # See `Consensus.Discovery.Telemetry`.
        :telemetry.span([:consensus, :discovery, :geocode], %{query: query}, fn ->
          case Cache.get(cache_key) do
            {:hit, result} ->
              {result, geocode_stop_metadata(query, result, :hit)}

            :miss ->
              {result, cacheable?} = safe_lookup(query, build)

              if cacheable? do
                Cache.put(cache_key, result, ttl_ms: @success_ttl_ms, error_ttl_ms: @error_ttl_ms)
              end

              {result, geocode_stop_metadata(query, result, :miss)}
          end
        end)
    end
  end

  ## Telemetry shaping (see Consensus.Discovery.Telemetry)

  # span/3's stop event carries only what the function returns — start metadata
  # is not merged in — so `query` is repeated rather than assumed.
  defp geocode_stop_metadata(query, {:ok, %Area{} = area}, cache) do
    %{
      query: query,
      url: request_url(query),
      outcome: :ok,
      cache: cache,
      name: area.name,
      bbox: Area.encode_bbox(area)
    }
  end

  defp geocode_stop_metadata(query, {:ok, {lat, lon}}, cache) do
    %{
      query: query,
      url: request_url(query),
      outcome: :ok,
      cache: cache,
      name: "point",
      bbox: "#{lat},#{lon}"
    }
  end

  defp geocode_stop_metadata(query, {:error, reason}, cache),
    do: %{
      query: query,
      url: request_url(query),
      outcome: :error,
      reason: reason,
      cache: cache
    }

  ## Lookup

  defp safe_lookup(query, build) do
    perform_lookup(query, build)
  rescue
    exception ->
      Logger.error(
        "Consensus.Discovery.Geocoder: geocode of #{inspect(query)} raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {{:error, :geocode_failed}, true}
  catch
    kind, reason ->
      Logger.error(
        "Consensus.Discovery.Geocoder: geocode of #{inspect(query)} exited: " <>
          inspect({kind, reason})
      )

      {{:error, :geocode_failed}, true}
  end

  @doc false
  # Public so the telemetry handler can log a pasteable URL, and so a test can
  # pin the query string. Built by the client from the same params the request
  # uses, so the logged URL and the sent URL cannot drift apart.
  def request_url(query), do: Nominatim.request_url(request_params(query))

  defp request_params(query) do
    case Application.get_env(:consensus, __MODULE__, [])[:countrycodes] do
      codes when is_binary(codes) and codes != "" ->
        [q: query, format: "jsonv2", limit: 1, countrycodes: codes]

      _none ->
        [q: query, format: "jsonv2", limit: 1]
    end
  end

  # Returns {result, cacheable?}. Only a gate refusal is not cacheable.
  defp perform_lookup(query, build) do
    case Nominatim.search(request_params(query)) do
      {:ok, [place | _rest]} -> {build.(query, place), true}
      {:ok, []} -> {{:error, :not_found}, true}
      {:error, :busy} -> {{:error, :geocode_failed}, false}
      {:error, _reason} -> {{:error, :geocode_failed}, true}
    end
  end

  # Nominatim's boundingbox order is [min_lat, max_lat, min_lon, max_lon]
  # (south, north, west, east); Area's bbox is {min_lat, min_lon, max_lat,
  # max_lon} — the reordering below is the whole point of doing it here, once.
  defp build_area(query, %{"boundingbox" => [min_lat, max_lat, min_lon, max_lon]} = place) do
    with {:ok, min_lat} <- to_coord(min_lat),
         {:ok, min_lon} <- to_coord(min_lon),
         {:ok, max_lat} <- to_coord(max_lat),
         {:ok, max_lon} <- to_coord(max_lon) do
      name = presence(place["name"]) || presence(place["display_name"]) || query
      {:ok, %Area{name: name, bbox: {min_lat, min_lon, max_lat, max_lon}}}
    else
      _ -> {:error, :geocode_failed}
    end
  end

  defp build_area(_query, _place), do: {:error, :geocode_failed}

  defp build_point(_query, %{"lat" => lat, "lon" => lon}) do
    with {:ok, lat} when lat >= -90 and lat <= 90 <- to_coord(lat),
         {:ok, lon} when lon >= -180 and lon <= 180 <- to_coord(lon) do
      {:ok, {lat / 1, lon / 1}}
    else
      _ -> {:error, :geocode_failed}
    end
  end

  defp build_point(_query, _place), do: {:error, :geocode_failed}

  defp to_coord(value) when is_number(value), do: {:ok, value}

  defp to_coord(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp to_coord(_value), do: :error

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
