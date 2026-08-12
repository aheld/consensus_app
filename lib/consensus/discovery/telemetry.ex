defmodule Consensus.Discovery.Telemetry do
  @moduledoc """
  Turns the Assisted Add's `:telemetry` spans into one readable chain in the log.

  ## Why spans emitted here, and logs consumed here

  The domain emits `:telemetry` events; *this* module decides they become log
  lines. That split is the Elixir convention (Ecto, Phoenix, Req and Bandit all
  work this way, and `ConsensusWeb.Telemetry` already charts their events), and it
  is what keeps the emit sites free of any opinion about where the output goes.
  `Consensus.Discovery` does not know this module exists.

  It also leaves the upgrade path open. These are `:telemetry.span/3` events, so
  they already carry `telemetry_span_context`, start/stop/exception and a
  duration — the shape a tracer wants. If a collector ever exists,
  `opentelemetry_telemetry` bridges them into real spans without touching a
  single emit site. **OpenTelemetry itself is deliberately not a dependency:** a
  span is only worth exporting if something collects it, this deployment is one
  Fly machine whose only sink is `fly logs` (D-012), and an exporter would add
  egress and a boot failure mode to a feature whose whole design principle is
  that failure is silence (D-052).

  ## Why the events are emitted at the domain boundary, not at the HTTP client

  Both lookups are cached — a geocode for a year, a search for the provider's
  own TTL — so **the HTTP layer cannot see most of what happens.** Instrumenting
  `Geocoder.HTTP.Req` would show nothing on a cache hit and invite the reading
  that nothing ran. `Consensus.Discovery.search/3` and
  `Consensus.Discovery.Geocoder.geocode/1` are the spans instead, each carrying
  `cache: :hit | :miss`, so a hit is a visible outcome rather than an absence.

  Those two are also the functions whose contract is "never raises, always a
  tagged tuple", which makes their `:exception` events genuinely exceptional.

  ## The chain

      [lookup 7Kd2] geocode  q="philadelphia" cache=miss -> ok name="Philadelphia" bbox=39.867,-75.28,40.137,-74.955 (1340ms)
      [lookup 7Kd2] repro    https://nominatim.openstreetmap.org/search?q=philadelphia&format=jsonv2&limit=1
      [lookup 7Kd2] search   type=<type> q="vernick" area="Philadelphia" provider=Overpass cache=miss
      [lookup 7Kd2] overpass ql=[out:json][timeout:25]; ( node["amenity"="<tag>"]["name"~"vernick",i](39.867,...); ) out tags 10;
      [lookup 7Kd2] repro    https://overpass-api.de/api/interpreter?data=%5Bout%3Ajson%5D%5Btimeout%3A25%5D%3B...
      [lookup 7Kd2] overpass -> 200 (690ms)
      [lookup 7Kd2] search   -> ok 1 result (695ms)
      [lookup 7Kd2] enrich   url="https://vernickphilly.com/" cache=miss -> ok title="Vernick Food & Drink" image=yes (500ms)

  (`<type>` and `<tag>` stand in for real values above on purpose:
  `test/consensus/activity_type_invariant_test.exs` reserves the literal to the
  one schema that declares it as a column default, and that pin is worth more
  than a more concrete example. The real lines carry the actual strings.)

  Every `repro` line is a **GET you can paste into a browser or curl** — including
  the Overpass one, which is the GET equivalent of the POST the adapter actually
  sends (Overpass accepts the program as a `data` parameter). `grep repro` over
  the log is a list of reproducible requests and nothing else. Both URLs are built
  by the module that issues the request, so a `repro` line that works is evidence
  about the real call rather than a second, driftable reconstruction of it.

  A `repro` line appears on a cache **hit** too, for the geocode: the URL is a pure
  function of the query, and a cached answer is exactly when you want to check what
  the upstream would say now.

  The `overpass ql=` line is the one that cannot be reconstructed from anything
  else: it is where the bbox, the registered tag list and the two escaping layers
  actually combine, and it is logged on `:start` — before the result — because
  that is the order the question gets asked in.

  ## The correlation id crosses a process boundary, and that is not free

  The assist runs in `start_async`, so the work happens in a **Task, not the
  LiveView**. `Logger` metadata is process-local and is not inherited, and there
  is no `request_id` either — the request arrived on a websocket, not through the
  Plug pipeline. So `ConsensusWeb.GroupLive.Options` sets `Logger.metadata(cid:
  ...)` *inside* the closure, and this module reads it back with
  `Logger.metadata/0`, which works because a `:telemetry` handler runs
  synchronously in the process that emitted the event. Nothing is threaded
  through a function signature, so `search/3`'s arity — pinned by
  `test/consensus/activity_type_invariant_test.exs` — is untouched.

  A line with no `cid` (the paste path reaching `LinkPreview` directly, say)
  renders as `[lookup]` rather than inventing one.

  ## What is logged, and the privacy call

  The venue query and the typed area are user input, logged at `:info`. The area
  string can be a home neighbourhood or postcode, so this is a deliberate choice
  rather than an oversight: it is the only way to answer "why did this lookup
  return nothing", and it is the same trade `Consensus.Accounts`' `[audit]` lines
  make. Nothing here logs a token, a slug, a session or a participant. Turn the
  whole thing down without a deploy by configuring a different level:

      config :consensus, Consensus.Discovery.Telemetry, level: :debug

  `level: nil` (or `false`) attaches nothing at all.
  """

  require Logger

  @events [
    [:consensus, :discovery, :geocode, :stop],
    [:consensus, :discovery, :geocode, :exception],
    [:consensus, :discovery, :search, :start],
    [:consensus, :discovery, :search, :stop],
    [:consensus, :discovery, :search, :exception],
    [:consensus, :discovery, :provider_request, :start],
    [:consensus, :discovery, :provider_request, :stop],
    [:consensus, :discovery, :provider_request, :exception],
    [:consensus, :link_preview, :fetch, :stop],
    [:consensus, :link_preview, :fetch, :exception]
  ]

  @handler_id "consensus-discovery-log"

  # A QL program is ~300 characters; the cap is a guard against a pathological
  # tag list rather than an expected truncation.
  @max_ql_chars 800
  @max_query_chars 120

  @doc """
  Attaches the log handler. Idempotent — a second call is `:ok`, not an error,
  so a test that re-attaches does not have to know whether boot already did.

  Returns `:ok` and attaches nothing when the configured level is `nil`/`false`.
  """
  @spec attach() :: :ok
  def attach do
    if level() do
      case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
        other -> log_attach_failure(other)
      end
    else
      :ok
    end
  rescue
    # This runs in `Consensus.Application.start/2`, before the supervisor. An
    # observability handler must never be the reason a release fails to boot —
    # the same rule invariant 9 puts on mail delivery, for the same reason: the
    # app's actual job does not depend on it. A machine that boots blind is
    # recoverable; a machine that does not boot is an outage.
    exception -> log_attach_failure(exception)
  end

  defp log_attach_failure(reason) do
    Logger.error(
      "Consensus.Discovery.Telemetry: could not attach the lookup log handler " <>
        "(#{inspect(reason)}). The app is running; the assist chain is not logged."
    )

    :ok
  end

  @doc "Removes the handler. Only tests need this."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  # Public because :telemetry warns (and pays a performance cost) for handlers
  # given as anonymous functions — the capture above must resolve to a real one.
  def handle_event([:consensus, :discovery, :geocode, :stop], measurements, meta, _config) do
    log([
      "geocode  q=",
      quoted(meta[:query]),
      " cache=",
      to_string(meta[:cache]),
      " -> ",
      outcome_phrase(meta),
      geocode_detail(meta),
      duration(measurements)
    ])

    repro(meta[:url])
  end

  def handle_event([:consensus, :discovery, :search, :start], _measurements, meta, _config) do
    log([
      "search   type=",
      to_string(meta[:activity_type]),
      " q=",
      quoted(meta[:query]),
      " area=",
      quoted(meta[:area]),
      " provider=",
      provider_name(meta[:provider])
    ])
  end

  def handle_event([:consensus, :discovery, :search, :stop], measurements, meta, _config) do
    log([
      "search   cache=",
      to_string(meta[:cache]),
      " -> ",
      outcome_phrase(meta),
      results_detail(meta),
      duration(measurements)
    ])
  end

  def handle_event([:consensus, :discovery, :provider_request, :start], _measurements, meta, _) do
    log(["overpass ql=", flatten_ql(meta[:ql])])
    repro(meta[:url])
  end

  def handle_event([:consensus, :discovery, :provider_request, :stop], measurements, meta, _) do
    log(["overpass -> ", to_string(meta[:status] || meta[:outcome]), duration(measurements)])
  end

  def handle_event([:consensus, :link_preview, :fetch, :stop], measurements, meta, _config) do
    log([
      "enrich   url=",
      quoted(meta[:url]),
      " cache=",
      to_string(meta[:cache]),
      " -> ",
      outcome_phrase(meta),
      preview_detail(meta),
      duration(measurements)
    ])
  end

  # Every span's :exception clause. These should never fire — each instrumented
  # function rescues into a tagged tuple — so one is a real defect, logged at
  # :error regardless of the configured level.
  def handle_event([:consensus | _rest] = event, measurements, meta, _config) do
    Logger.error([
      prefix(),
      Enum.map_join(event, ".", &to_string/1),
      " RAISED ",
      inspect(meta[:kind]),
      " ",
      inspect(meta[:reason]),
      duration(measurements)
    ])
  end

  ## Rendering

  defp log(iodata) do
    Logger.log(level(), fn -> IO.iodata_to_binary([prefix(), iodata]) end)
  end

  # Its own line, and deliberately tagged rather than folded into the summary
  # above: `fly logs | grep repro` is then exactly the list of requests you can
  # paste into a browser or curl, with nothing else to strip. The URL is built
  # by the module that makes the request, never reassembled here, so a logged
  # URL that works is evidence about the real one.
  defp repro(nil), do: :ok
  defp repro(url) when is_binary(url), do: log(["repro    ", url])
  defp repro(_other), do: :ok

  defp prefix do
    case Logger.metadata()[:cid] do
      nil -> "[lookup] "
      cid -> ["[lookup ", to_string(cid), "] "]
    end
  end

  defp outcome_phrase(meta) do
    case meta[:outcome] do
      :ok -> "ok"
      nil -> "ok"
      other -> ["ERR ", to_string(other), reason_detail(meta)]
    end
  end

  defp reason_detail(meta) do
    case meta[:reason] do
      nil -> []
      reason -> [" reason=", inspect(reason)]
    end
  end

  defp geocode_detail(%{outcome: :ok} = meta) do
    [" name=", quoted(meta[:name]), " bbox=", to_string(meta[:bbox] || "-")]
  end

  defp geocode_detail(_meta), do: []

  defp results_detail(%{outcome: :ok} = meta) do
    count = meta[:count] || 0
    [" ", to_string(count), " ", pluralize(count, "result")]
  end

  defp results_detail(_meta), do: []

  defp preview_detail(%{outcome: :ok} = meta) do
    [" title=", quoted(meta[:title]), " image=", if(meta[:image?], do: "yes", else: "no")]
  end

  defp preview_detail(_meta), do: []

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp duration(%{duration: native}) do
    [" (", to_string(System.convert_time_unit(native, :native, :millisecond)), "ms)"]
  end

  defp duration(_measurements), do: []

  defp provider_name(module) when is_atom(module) and not is_nil(module) do
    module |> Module.split() |> List.last()
  end

  defp provider_name(_other), do: "none"

  # The QL program is a multi-line heredoc; a log line that wraps is a log line
  # nobody greps. Collapsed to one line, with runs of whitespace squeezed.
  defp flatten_ql(ql) when is_binary(ql) do
    ql
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@max_ql_chars)
  end

  defp flatten_ql(_other), do: "-"

  defp quoted(nil), do: "-"

  defp quoted(value) when is_binary(value) do
    [?", value |> String.replace("\"", "'") |> truncate(@max_query_chars), ?"]
  end

  defp quoted(value), do: quoted(to_string(value))

  defp truncate(string, max) do
    if String.length(string) > max do
      String.slice(string, 0, max) <> "…"
    else
      string
    end
  end

  defp level do
    case Application.get_env(:consensus, __MODULE__, []) do
      opts when is_list(opts) -> Keyword.get(opts, :level, :info)
      _other -> :info
    end
  end
end
