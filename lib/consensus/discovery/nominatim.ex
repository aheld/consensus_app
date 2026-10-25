defmodule Consensus.Discovery.Nominatim do
  @moduledoc """
  The one Nominatim client. Both callers go through it:
  `Consensus.Discovery.Geocoder` (an area string → a bbox) and
  `Consensus.Discovery.Provider.Nominatim` (a typed venue name → POIs).

  It owns everything Nominatim's usage policy
  (docs/research/activity-discovery.md trap F) makes load-bearing, so no
  caller can get it wrong on its own:

    * **The endpoint and an identifying User-Agent** (`@user_agent`, naming the
      app and where to find it). Nominatim blocks anonymous or
      browser-imitating agents.
    * **One request per second per application**, enforced by the one
      `Consensus.Discovery.Nominatim.Gate`. Two callers carrying their own
      copies of the endpoint would mean two gates that cannot see each other.
      A request that would wait more than `@max_wait_ms` for its slot is not
      sent at all and answers `{:error, :busy}`.
    * **Timeouts**: 5s to connect, 10s to receive.

  Caching is the callers' job, and deliberately sits *above* this module: a
  cache hit never reaches the gate.

  No autocomplete: nothing here may ever be called per keystroke, and every
  call comes from `start_async/3`, never inline in a `handle_event` (CLAUDE.md
  invariant 13 — a gated wait plus a network request with multi-second
  budgets).

  `search/1` never raises.
  """

  alias Consensus.Discovery.Nominatim.Gate

  require Logger

  @endpoint "https://nominatim.openstreetmap.org/search"
  @user_agent "Consensus/0.2 (group activity planning app; https://dinner.isourthing.com)"
  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000
  # An organizer who adds five names in four seconds gets the first four looked
  # up and the fifth stays silent — better than a ten-second tail behind the
  # shimmer (docs/plans/nominatim-lookup.md §1.4).
  @max_wait_ms 3_000

  @typedoc """
    * `:busy` — the gate refused: the slot was more than `@max_wait_ms` away,
      so nothing was asked. Callers must not cache it — there is no answer to
      remember.
    * `:rate_limited` — HTTP 429.
    * `{:http, status}` — any other non-200, including the 403 Nominatim
      answers a policy breach with.
    * `:timeout` — the transport gave up waiting.
    * `:malformed` — a 200 whose body is not a JSON list.
    * `:search_failed` — any other transport error, or anything raised.
  """
  @type error ::
          :busy
          | :rate_limited
          | {:http, pos_integer()}
          | :timeout
          | :malformed
          | :search_failed

  @doc """
  Sends one gated GET to `/search` with `params` and returns the decoded JSON
  list. Never raises.
  """
  @spec search(keyword()) :: {:ok, [map()]} | {:error, error()}
  def search(params) when is_list(params) do
    with {:ok, wait_ms} <- reserve() do
      if wait_ms > 0, do: Process.sleep(wait_ms)
      safe_get(params)
    end
  end

  @doc """
  The exact GET `search/1` sends for `params`. Public so the telemetry handler
  can log a pasteable `repro` line (D-056) built from the same expression that
  goes on the wire, rather than a second reconstruction that can drift.
  """
  @spec request_url(keyword()) :: String.t()
  def request_url(params), do: @endpoint <> "?" <> URI.encode_query(params)

  # A gate that is down (it is restarting, or a test runs without the app)
  # is a refusal, not a crash.
  defp reserve do
    Gate.reserve(@max_wait_ms)
  catch
    :exit, reason ->
      Logger.error("Consensus.Discovery.Nominatim: rate gate unavailable: #{inspect(reason)}")
      {:error, :search_failed}
  end

  defp safe_get(params) do
    get(params)
  rescue
    exception ->
      Logger.error(
        "Consensus.Discovery.Nominatim: request raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :search_failed}
  catch
    kind, reason ->
      Logger.error("Consensus.Discovery.Nominatim: request exited: " <> inspect({kind, reason}))

      {:error, :search_failed}
  end

  defp get(params) do
    request_opts = [
      headers: [{"user-agent", @user_agent}],
      connect_timeout_ms: @connect_timeout_ms,
      receive_timeout_ms: @receive_timeout_ms
    ]

    case http_module().get(request_url(params), request_opts) do
      {:ok, %{status: 200, body: body}} -> decode(body)
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, places} when is_list(places) -> {:ok, places}
      _other -> {:error, :malformed}
    end
  end

  # Req/Mint transport errors carry their cause in a :reason field; a bare
  # :timeout covers doubles and simpler transports.
  defp transport_error(:timeout), do: :timeout
  defp transport_error(%{reason: :timeout}), do: :timeout
  defp transport_error(_reason), do: :search_failed

  defp http_module do
    Application.get_env(:consensus, __MODULE__, [])[:http] ||
      Consensus.Discovery.Nominatim.HTTP.Req
  end
end
