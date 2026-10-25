defmodule Consensus.Discovery.Nominatim.HTTP do
  @moduledoc """
  Behaviour for the single HTTP request `Consensus.Discovery.Nominatim.search/1`
  makes per (uncached, gate-admitted) call — for both of its callers, the
  geocoder and the POI provider.

  Configured via `Application.get_env(:consensus, Consensus.Discovery.Nominatim)[:http]`
  so tests can inject a module-based double (no Mox in this project), exactly the
  shape `Consensus.LinkPreview.Fetcher` established; `config/test.exs` points it
  at `Consensus.NominatimHTTPStub`. Unset, the client uses
  `Consensus.Discovery.Nominatim.HTTP.Req` below.

  Deliberately **not** a reuse of `Consensus.LinkPreview.Fetcher` — that
  behaviour is shaped for a caller-driven redirect loop with a per-hop SSRF
  re-check over an arbitrary user-pasted URL. This is a JSON GET against one
  fixed, configured host, and the research (§4.2) says the two must not be
  merged.
  """

  @type response :: %{status: pos_integer(), body: binary()}

  @doc """
  Issues one GET to `url` and returns the raw response. `opts` carries
  `:headers` (a `[{name, value}]` list — the Nominatim-required `User-Agent`
  arrives this way), `:connect_timeout_ms` and `:receive_timeout_ms`; a real
  implementation honours all three. The body comes back as the raw binary —
  the client does its own JSON decoding.
  """
  @callback get(url :: String.t(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end

defmodule Consensus.Discovery.Nominatim.HTTP.Req do
  @moduledoc """
  The real `Consensus.Discovery.Nominatim.HTTP`, backed by `Req`.

  `decode_body: false` matters: Req would otherwise decode Nominatim's
  `application/json` response into terms itself, and the behaviour's contract is
  a raw binary body (so a stubbed response and a real one exercise the same
  parsing in the client).

  Sharing this file with the behaviour mirrors `Consensus.LinkPreview.Fetcher` —
  the same deliberate, narrow exception to one-module-per-file: the two are
  never used independently, and nothing here nests one `defmodule` inside
  another.
  """

  @behaviour Consensus.Discovery.Nominatim.HTTP

  @impl true
  def get(url, opts) do
    Req.new(
      url: url,
      headers: Keyword.get(opts, :headers, []),
      retry: false,
      connect_options: [timeout: Keyword.fetch!(opts, :connect_timeout_ms)],
      receive_timeout: Keyword.fetch!(opts, :receive_timeout_ms)
    )
    |> Req.get(decode_body: false)
    |> case do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body || ""}}
      {:error, reason} -> {:error, reason}
    end
  end
end
