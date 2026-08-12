defmodule Consensus.Discovery.Provider.Overpass do
  @moduledoc """
  The stage-1 live `Consensus.Discovery.Provider`: name lookup against the
  public Overpass API (OpenStreetMap data), per
  docs/research/activity-discovery.md §4 and the assisted-add brief.

  One module serves every OSM-backed activity type — the per-type knowledge is
  the `tags: [{key, value}]` list each registry entry carries (for example
  `{"leisure", "bowling_alley"}` or `{"amenity", "cinema"}`), which arrives in
  `opts` and lands in the generated QL verbatim. Nothing here knows which type
  it is answering for, which is what keeps CLAUDE.md product invariant 2
  checkable (research §4.4: four types, one module, different data).

  ## The query

  `search/3` builds one Overpass QL program: nodes and ways carrying the
  configured tags, whose `name` matches the query case-insensitively as a
  literal (regex metacharacters in the query are escaped, then the whole thing
  is QL-string-escaped — a quote in a venue name must never terminate the QL
  string), inside the area's bbox. `[out:json]` with a 10-second server-side
  timeout, `out tags` with a small server-side cap — `Consensus.Discovery` caps
  display at 3, the cap here just keeps the response body honest, and `tags`
  verbosity keeps it honest the other way: the element mapper reads only
  type/id/tags, so geometry and way member lists are never requested
  (`Result` deliberately has nowhere to put a lat/lon — research §4.1).

  The receive timeout is ~10s, deliberately looser than
  `Consensus.LinkPreview`'s 5s: measured Overpass latency runs 1.5–14s
  (research §4.6), and 5s would turn a working answer into silence.

  ## What comes back

  Only named elements survive (an unnamed node is not a suggestion anyone can
  recognise). `website_url` is taken from the `website` | `contact:website` |
  `url` tags, **first valid** — and "valid" includes the SSRF guard: OSM tags
  are crowd-edited, so a URL that comes back from Overpass is
  attacker-influenceable input (research trap J). Every candidate must be an
  absolute http(s) URL with a host *and* pass
  `Consensus.LinkPreview.check_host/1` — the same allowlist the paste path
  enforces, never a second one that drifts. An invalid or blocked URL nulls the
  field, never drops the result: the name + address suggestion is still useful.

  ## Errors (research trap L)

  Every failure is a tagged tuple; `search/3` never raises. HTTP 429
  (rate-limited: the public instance's slot pool is shared and undocumented)
  and 504 (the instance timed out or ran out of memory — "that area is too
  big") are first-class, distinct outcomes, not collapsed into one
  `:unavailable`. Transport timeouts, unparseable bodies and other statuses
  each get their own tag; see `t:error/0`.
  """

  @behaviour Consensus.Discovery.Provider

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Result
  alias Consensus.LinkPreview

  require Logger

  @endpoint "https://overpass-api.de/api/interpreter"
  @user_agent "Consensus/0.2 (group activity planning app; https://dinner.isourthing.com)"
  @connect_timeout_ms 5_000
  # Research §4.6: measured Overpass latency is 1.5–14s; LinkPreview's 5s is too
  # tight here. The server-side [timeout:10] below matches this budget.
  @receive_timeout_ms 10_000
  @server_timeout_s 10
  # Discovery caps display at 3; asking for a few more means dropped unnamed
  # elements cannot starve the list, while still bounding the response.
  @server_result_cap 10
  @ttl_ms :timer.minutes(15)
  @error_ttl_ms :timer.minutes(1)

  @website_tags ["website", "contact:website", "url"]

  @typedoc """
  The four-way taxonomy from research trap L, plus the generic fallback:

    * `:rate_limited` — HTTP 429. Expected, not exceptional; no retry storm.
    * `:gateway_timeout` — HTTP 504: the query, not the service, is the problem.
    * `:timeout` — the transport gave up waiting.
    * `:malformed` — a 200 whose body is not the JSON shape Overpass documents.
    * `{:http, status}` — any other non-200. (`Consensus.Discovery` degrades
      this non-atom tag to `:search_failed` at its boundary; the distinction
      still exists here for logging and direct callers.)
    * `:search_failed` — a non-timeout transport error, or anything raised.
  """
  @type error ::
          :rate_limited
          | :gateway_timeout
          | :timeout
          | :malformed
          | {:http, pos_integer()}
          | :search_failed

  @impl true
  def search(query, area, opts)

  def search(query, %Area{bbox: bbox}, opts) when is_binary(query) and is_list(opts) do
    tags = Keyword.get(opts, :tags, [])
    query = sanitize_query(query)

    # Both refusals answer with the brief's silence rather than a query the
    # public instance would resent: an empty tag list is a registry
    # misconfiguration that would name-match every element in the bbox, and a
    # query that sanitises to "" (control characters only — Discovery already
    # short-circuits whitespace blanks) would become a match-everything regex.
    if tags == [] or query == "" do
      {:ok, []}
    else
      safe_search(query, bbox, tags)
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

  @doc """
  The Overpass QL program `search/3` sends for `query`, `bbox` and `tags`.
  Public so tests can pin the generated text (escaping is load-bearing here);
  not part of the `Consensus.Discovery.Provider` contract.

  Escapes the query it is given, verbatim; flattening control characters is
  `search/3`'s job (`sanitize_query/1` runs exactly once, there, where the
  sanitised text also decides the empty-query refusal).
  """
  @spec build_ql(String.t(), Area.bbox(), [{String.t(), String.t()}]) :: String.t()
  def build_ql(query, {min_lat, min_lon, max_lat, max_lon}, tags) do
    # Overpass bbox order is (south, west, north, east) — the same order
    # Area.bbox already carries.
    bbox = Enum.map_join([min_lat, min_lon, max_lat, max_lon], ",", &coord_to_string/1)

    tag_filters =
      Enum.map_join(tags, "", fn {key, value} ->
        ~s(["#{escape_ql_string(key)}"="#{escape_ql_string(value)}"])
      end)

    # Two escaping layers, applied inside-out: regex-escape so the query is a
    # literal match (a "." in a venue name must not become a wildcard, a stray
    # "[" must not 400 the whole program), then QL-string-escape so no quote or
    # backslash in the query can terminate the QL string and inject statements.
    name_regex = query |> escape_regex() |> escape_ql_string()
    name_filter = ~s(["name"~"#{name_regex}",i])

    """
    [out:json][timeout:#{@server_timeout_s}];
    (
      node#{tag_filters}#{name_filter}(#{bbox});
      way#{tag_filters}#{name_filter}(#{bbox});
    );
    out tags #{@server_result_cap};
    """
  end

  ## The request

  @doc false
  # The GET equivalent of the POST this adapter actually sends. Overpass accepts
  # the program as a `data` query parameter, so this is pasteable into a browser
  # or curl — which is the whole point: it turns "what did the app ask?" into
  # something reproducible without reconstructing the QL by hand. Derived from
  # the same `ql` that goes on the wire, never rebuilt independently.
  def repro_url(ql), do: @endpoint <> "?" <> URI.encode_query(data: ql)

  defp safe_search(query, bbox, tags) do
    perform_search(query, bbox, tags)
  rescue
    exception ->
      Logger.error(
        "Consensus.Discovery.Provider.Overpass: search for #{inspect(query)} raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :search_failed}
  catch
    kind, reason ->
      Logger.error(
        "Consensus.Discovery.Provider.Overpass: search for #{inspect(query)} exited: " <>
          inspect({kind, reason})
      )

      {:error, :search_failed}
  end

  defp perform_search(query, bbox, tags) do
    ql = build_ql(query, bbox, tags)

    request_opts = [
      headers: [{"user-agent", @user_agent}],
      connect_timeout_ms: @connect_timeout_ms,
      receive_timeout_ms: @receive_timeout_ms
    ]

    # The QL goes out on the span's :start, deliberately — it is the one thing
    # in the chain that cannot be reconstructed from anything else (the bbox,
    # the registered tag list and both escaping layers only ever combine here),
    # and an operator wants to read the question before the answer. The :stop
    # carries the HTTP status separately from Discovery's own timing, which is
    # what tells "Overpass was slow" apart from "we were slow".
    :telemetry.span(
      [:consensus, :discovery, :provider_request],
      %{provider: __MODULE__, ql: ql, url: repro_url(ql), bbox: bbox, tags: tags},
      fn ->
        result =
          case http_module().post(@endpoint, ql, request_opts) do
            {:ok, %{status: 200, body: body}} -> parse_body(body)
            {:ok, %{status: 429}} -> {:error, :rate_limited}
            {:ok, %{status: 504}} -> {:error, :gateway_timeout}
            {:ok, %{status: status}} -> {:error, {:http, status}}
            {:error, reason} -> {:error, transport_error(reason)}
          end

        {result, request_stop_metadata(result)}
      end
    )
  end

  # span/3 does not merge start metadata into the stop event, so the status is
  # derived from the outcome rather than carried forward from the request.
  defp request_stop_metadata({:ok, results}) when is_list(results),
    do: %{outcome: :ok, status: 200, count: length(results)}

  defp request_stop_metadata({:error, :rate_limited}),
    do: %{outcome: :error, status: 429, reason: :rate_limited}

  defp request_stop_metadata({:error, :gateway_timeout}),
    do: %{outcome: :error, status: 504, reason: :gateway_timeout}

  defp request_stop_metadata({:error, {:http, status}}),
    do: %{outcome: :error, status: status, reason: {:http, status}}

  defp request_stop_metadata({:error, reason}),
    do: %{outcome: :error, status: nil, reason: reason}

  # Req/Mint transport errors carry their cause in a :reason field; a bare
  # :timeout covers doubles and simpler transports.
  defp transport_error(:timeout), do: :timeout
  defp transport_error(%{reason: :timeout}), do: :timeout
  defp transport_error(_reason), do: :search_failed

  defp http_module do
    Application.get_env(:consensus, __MODULE__, [])[:http] ||
      Consensus.Discovery.Provider.Overpass.HTTP.Req
  end

  ## QL escaping

  # Control characters (a pasted newline, a smuggled NUL) have no place in a
  # name lookup and complicate both escaping layers — flatten them to spaces.
  #
  # String.valid?/1 is checked first: the ~r/.../u regex below requires valid
  # UTF-8 and *raises* ArgumentError on a binary that isn't (a query is
  # attacker-influenceable input, arriving straight from a paste), which
  # search/3's `safe_search` rescue does not cover — sanitize_query/1 runs
  # before that boundary. Invalid input degrades to "", which the caller
  # already treats as the brief's silence (search/3 short-circuits to
  # `{:ok, []}` on an empty sanitised query), never a raise.
  defp sanitize_query(query) do
    if String.valid?(query) do
      query
      |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
      |> String.trim()
    else
      ""
    end
  end

  # POSIX-ERE metacharacters, escaped so the query matches literally. The
  # backslashes this introduces are themselves escaped by escape_ql_string/1.
  defp escape_regex(query) do
    String.replace(query, ~r/[\\.\[\](){}*+?|^$]/, fn match -> "\\" <> match end)
  end

  # Overpass QL string escaping: backslash first (so the quote escape below is
  # not itself doubled), then the double quote that would terminate the string.
  defp escape_ql_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp coord_to_string(value) when is_float(value), do: Float.to_string(value)
  defp coord_to_string(value) when is_integer(value), do: Integer.to_string(value)

  ## Element → Result mapping

  defp parse_body(body) do
    case Jason.decode(body) do
      {:ok, %{"elements" => elements}} when is_list(elements) ->
        {:ok, Enum.flat_map(elements, &map_element/1)}

      {:ok, _other} ->
        {:error, :malformed}

      {:error, _reason} ->
        {:error, :malformed}
    end
  end

  # Only named nodes/ways become suggestions — an unnamed element is nothing an
  # organizer can recognise, and the query above only asks for those two types.
  defp map_element(%{"type" => type, "id" => id, "tags" => %{"name" => name} = tags})
       when type in ["node", "way"] and is_binary(name) and is_integer(id) do
    case String.trim(name) do
      "" ->
        []

      trimmed_name ->
        [
          %Result{
            name: trimmed_name,
            website_url: website_url(tags),
            source: :osm,
            external_ref: "#{type}/#{id}",
            chips: chips(tags),
            address: address(tags)
          }
        ]
    end
  end

  defp map_element(_element), do: []

  # First *valid* candidate wins — validity includes the SSRF allowlist (trap
  # J): absolute http(s) with a host, and the host passes the same
  # LinkPreview.check_host/1 the paste path runs. All invalid → nil, never a
  # dropped result.
  defp website_url(tags) do
    @website_tags
    |> Enum.map(&Map.get(tags, &1))
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

  defp address(%{"addr:housenumber" => number, "addr:street" => street})
       when is_binary(number) and is_binary(street) do
    case {String.trim(number), String.trim(street)} do
      {"", ""} -> nil
      {"", street} -> street
      {_number, ""} -> nil
      {number, street} -> "#{number} #{street}"
    end
  end

  defp address(%{"addr:street" => street}) when is_binary(street) do
    case String.trim(street) do
      "" -> nil
      street -> street
    end
  end

  defp address(_tags), do: nil

  # The cuisine tag is semicolon-multivalued ("thai;noodles") — the first value
  # is the chip, underscores humanised to spaces.
  defp chips(%{"cuisine" => cuisine}) when is_binary(cuisine) do
    value =
      cuisine
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.replace("_", " ")

    if value == "", do: nil, else: [{"cuisine", value}]
  end

  defp chips(_tags), do: nil
end
