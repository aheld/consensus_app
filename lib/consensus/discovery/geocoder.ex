defmodule Consensus.Discovery.Geocoder do
  @moduledoc """
  Turns a typed neighbourhood/city string into a `Consensus.Discovery.Area` via
  Nominatim — **submit-only**, per the area-prompt spec
  (docs/design/assisted-add-ux-brief.md F2) and Nominatim's usage policy, which
  forbids autocomplete outright (docs/research/activity-discovery.md trap F).
  Nothing here may ever be called per keystroke; one call per submitted form,
  and from `start_async/3`, never inline in a `handle_event` (CLAUDE.md
  invariant 13 — this is a network request with multi-second budgets).

  Two more Nominatim policy requirements are load-bearing here, not niceties:

    * **An identifying User-Agent.** Every request carries `@user_agent`, which
      names the app and where to find it. Nominatim blocks anonymous or
      browser-imitating agents.
    * **Caching.** Successful geocodes are cached effectively indefinitely
      (`@success_ttl_ms`, one year) in `Consensus.Discovery.Cache` — a
      neighbourhood's bounding box is immutable at the resolution we use, and
      re-asking a volunteer service the same question is exactly what its policy
      exists to stop. Failures are cached briefly (`@error_ttl_ms`) so a
      transient outage heals without hammering the endpoint either.

  `geocode/1` never raises: every failure is a tagged tuple, per
  `Consensus.LinkPreview.fetch/1`'s contract.
  """

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Cache

  require Logger

  @endpoint "https://nominatim.openstreetmap.org/search"
  @user_agent "Consensus/0.2 (group activity planning app; https://dinner.isourthing.com)"
  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000
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
  def geocode(area_string) when is_binary(area_string) do
    case String.trim(area_string) do
      "" ->
        {:error, :invalid_area}

      query ->
        cache_key = {:geocode, String.downcase(query)}

        # Spanned around the cache, not around the HTTP call: a success is
        # cached for ~a year, so the overwhelming majority of geocodes never
        # reach the network and an HTTP-level event would show nothing at all.
        # See `Consensus.Discovery.Telemetry`.
        :telemetry.span([:consensus, :discovery, :geocode], %{query: query}, fn ->
          case Cache.get(cache_key) do
            {:hit, result} ->
              {result, geocode_stop_metadata(query, result, :hit)}

            :miss ->
              result = safe_lookup(query)
              Cache.put(cache_key, result, ttl_ms: @success_ttl_ms, error_ttl_ms: @error_ttl_ms)
              {result, geocode_stop_metadata(query, result, :miss)}
          end
        end)
    end
  end

  def geocode(_area_string), do: {:error, :invalid_area}

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

  defp geocode_stop_metadata(query, {:error, reason}, cache),
    do: %{
      query: query,
      url: request_url(query),
      outcome: :error,
      reason: reason,
      cache: cache
    }

  ## Lookup

  defp safe_lookup(query) do
    perform_lookup(query)
  rescue
    exception ->
      Logger.error(
        "Consensus.Discovery.Geocoder: geocode of #{inspect(query)} raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :geocode_failed}
  catch
    kind, reason ->
      Logger.error(
        "Consensus.Discovery.Geocoder: geocode of #{inspect(query)} exited: " <>
          inspect({kind, reason})
      )

      {:error, :geocode_failed}
  end

  @doc false
  # Public so the telemetry handler can log a pasteable URL, and so a test can
  # pin the query string. Building it here — rather than in the handler — is
  # what stops the logged URL and the sent URL drifting apart: there is one
  # expression, and observability reads it rather than reimplementing it.
  def request_url(query),
    do: @endpoint <> "?" <> URI.encode_query(q: query, format: "jsonv2", limit: 1)

  defp perform_lookup(query) do
    url = request_url(query)

    request_opts = [
      headers: [{"user-agent", @user_agent}],
      connect_timeout_ms: @connect_timeout_ms,
      receive_timeout_ms: @receive_timeout_ms
    ]

    case http_module().get(url, request_opts) do
      {:ok, %{status: 200, body: body}} -> parse_body(query, body)
      {:ok, %{status: _status}} -> {:error, :geocode_failed}
      {:error, _reason} -> {:error, :geocode_failed}
    end
  end

  defp parse_body(query, body) do
    case Jason.decode(body) do
      {:ok, [place | _rest]} -> build_area(query, place)
      {:ok, []} -> {:error, :not_found}
      _other -> {:error, :geocode_failed}
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

  defp http_module do
    Application.get_env(:consensus, __MODULE__, [])[:http] ||
      Consensus.Discovery.Geocoder.HTTP.Req
  end
end
