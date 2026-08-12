defmodule Consensus.Discovery.Provider.Overpass.HTTP do
  @moduledoc """
  Behaviour for the single HTTP request `Consensus.Discovery.Provider.Overpass`
  makes per (uncached) search.

  Configured via
  `Application.get_env(:consensus, Consensus.Discovery.Provider.Overpass)[:http]`
  so tests can inject a module-based double (no Mox in this project), exactly the
  shape `Consensus.LinkPreview.Fetcher` and `Consensus.Discovery.Geocoder.HTTP`
  established; `config/test.exs` points it at `Consensus.OverpassHTTPStub` and
  `config/config.exs` at `Consensus.Discovery.Provider.Overpass.HTTP.Req` below.

  Deliberately **not** a reuse of `Consensus.LinkPreview.Fetcher` — that
  behaviour is shaped for a caller-driven redirect loop with a per-hop SSRF
  re-check over an arbitrary user-pasted URL. This is one POST of an Overpass QL
  program to one fixed, configured endpoint, and the research (§4.2) says the
  two must not be merged.
  """

  @type response :: %{status: pos_integer(), body: binary()}

  @doc """
  POSTs the Overpass QL program `ql` to `url` (as the form-encoded `data`
  parameter the interpreter expects) and returns the raw response. `opts`
  carries `:headers` (a `[{name, value}]` list — the identifying `User-Agent`
  arrives this way), `:connect_timeout_ms` and `:receive_timeout_ms`; a real
  implementation honours all three. The body comes back as the raw binary —
  the adapter does its own JSON decoding.
  """
  @callback post(url :: String.t(), ql :: String.t(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end

defmodule Consensus.Discovery.Provider.Overpass.HTTP.Req do
  @moduledoc """
  The real `Consensus.Discovery.Provider.Overpass.HTTP`, backed by `Req`.

  `decode_body: false` matters: Req would otherwise decode Overpass's
  `application/json` response into terms itself, and the behaviour's contract is
  a raw binary body (so a stubbed response and a real one exercise the same
  parsing in the adapter).

  Sharing this file with the behaviour mirrors `Consensus.LinkPreview.Fetcher`
  and `Consensus.Discovery.Geocoder.HTTP` — the same deliberate, narrow
  exception to one-module-per-file: the two are never used independently, and
  nothing here nests one `defmodule` inside another.
  """

  @behaviour Consensus.Discovery.Provider.Overpass.HTTP

  @impl true
  def post(url, ql, opts) do
    Req.new(
      url: url,
      headers: Keyword.get(opts, :headers, []),
      retry: false,
      connect_options: [timeout: Keyword.fetch!(opts, :connect_timeout_ms)],
      receive_timeout: Keyword.fetch!(opts, :receive_timeout_ms)
    )
    |> Req.post(form: [data: ql], decode_body: false)
    |> case do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body || ""}}
      {:error, reason} -> {:error, reason}
    end
  end
end
