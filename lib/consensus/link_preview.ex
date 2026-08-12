defmodule Consensus.LinkPreview do
  @moduledoc """
  Fetches a URL's OpenGraph / HTML metadata so an organizer's pasted link can prefill
  an option's title, description and image — every field stays editable afterwards,
  and an image is referenced by URL only; nothing here downloads or re-hosts one.

  Results (including failures) are cached by `Consensus.LinkPreview.Cache`, per the
  working agreement in CLAUDE.md that external API calls go through a caching layer
  from the first commit that touches them.

  This runs on the server against a URL a user pasted, so it carries an SSRF guard:
  only `http`/`https` URLs with a host are accepted, and the host — resolved, not just
  read off the URL — is rejected if it is loopback, private, or link-local, on every
  redirect hop as well as the first request. See `check_host/1`.
  """

  alias Consensus.LinkPreview.Cache
  alias Consensus.LinkPreview.Fetcher

  require Logger

  @enforce_keys [:url, :fetched_at]
  defstruct [:url, :title, :description, :image_url, :site_name, :fetched_at]

  @type t :: %__MODULE__{
          url: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          image_url: String.t() | nil,
          site_name: String.t() | nil,
          fetched_at: DateTime.t()
        }

  @max_redirects 3
  @max_body_bytes 512 * 1024
  @connect_timeout_ms 5_000
  @receive_timeout_ms 5_000
  @description_max_length 140

  @blocked_hostnames ~w(localhost metadata.google.internal)

  @doc """
  Fetches metadata for `url`.

  Every field but `url` and `fetched_at` is best-effort: a page with no OpenGraph tags
  and no `<title>` still comes back `{:ok, %__MODULE__{title: nil, ...}}`, not an
  error.

  Returns:
    * `{:error, :invalid_url}` — not an absolute `http`/`https` URL with a host.
    * `{:error, :blocked_host}` — the host resolves to (or literally is) a
      loopback/private/link-local address. Checked before the first request and again
      on every redirect hop.
    * `{:error, :too_many_redirects}` — more than 3 redirects.
    * `{:error, {:http, status}}` — a non-2xx, non-redirect response, or a redirect
      with no `location` header.
    * `{:error, :not_html}` — a 2xx response whose content type is not HTML.
    * `{:error, :fetch_failed}` — a transport error, or any exception/exit raised
      while fetching or parsing. Never raises into the caller.
    * `{:ok, %__MODULE__{}}` on success.
  """
  @spec fetch(String.t()) :: {:ok, t()} | {:error, atom()}
  def fetch(url) when is_binary(url) do
    with {:ok, uri} <- parse_and_validate(url),
         :ok <- check_host(uri.host) do
      normalized = normalize_url(uri)

      case Cache.get(normalized) do
        {:hit, result} -> result
        :miss -> fetch_and_cache(normalized)
      end
    end
  end

  ## Fetch + redirect loop

  defp fetch_and_cache(url) do
    result = safe_perform_fetch(url)
    Cache.put(url, result)
    result
  end

  defp safe_perform_fetch(url) do
    perform_fetch(url, 0)
  rescue
    exception ->
      Logger.error(
        "Consensus.LinkPreview: fetch of #{inspect(url)} raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :fetch_failed}
  catch
    kind, reason ->
      Logger.error(
        "Consensus.LinkPreview: fetch of #{inspect(url)} exited: " <>
          inspect({kind, reason})
      )

      {:error, :fetch_failed}
  end

  defp perform_fetch(url, redirects_followed) do
    case fetcher_module().get(url, fetch_opts()) do
      {:ok, %{status: status} = resp} when status in 300..399 ->
        if redirects_followed >= @max_redirects do
          {:error, :too_many_redirects}
        else
          follow_redirect(resp, url, redirects_followed + 1)
        end

      {:ok, %{status: status}} when status not in 200..299 ->
        {:error, {:http, status}}

      {:ok, resp} ->
        build_result(url, resp)

      {:error, _reason} ->
        {:error, :fetch_failed}
    end
  end

  defp follow_redirect(resp, current_url, redirects_followed) do
    case header(resp.headers, "location") do
      nil ->
        {:error, {:http, resp.status}}

      location ->
        next_url = current_url |> URI.merge(location) |> URI.to_string()

        with {:ok, uri} <- parse_and_validate(next_url),
             :ok <- check_host(uri.host) do
          perform_fetch(next_url, redirects_followed)
        end
    end
  end

  defp build_result(url, resp) do
    if html_content_type?(resp.headers) do
      metadata = Fetcher.Req.extract_metadata(resp.body, url)

      {:ok,
       %__MODULE__{
         url: url,
         title: metadata.title,
         description: truncate_description(metadata.description),
         image_url: metadata.image_url,
         site_name: metadata.site_name,
         fetched_at: DateTime.utc_now()
       }}
    else
      {:error, :not_html}
    end
  end

  defp fetch_opts do
    [
      connect_timeout_ms: @connect_timeout_ms,
      receive_timeout_ms: @receive_timeout_ms,
      max_body_bytes: @max_body_bytes
    ]
  end

  defp fetcher_module do
    Application.get_env(:consensus, __MODULE__, [])[:fetcher] || Fetcher.Req
  end

  defp html_content_type?(headers) do
    case header(headers, "content-type") do
      nil ->
        false

      value ->
        downcased = String.downcase(value)

        String.starts_with?(downcased, "text/html") or
          String.starts_with?(downcased, "application/xhtml+xml")
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  ## URL validation, normalisation and the SSRF guard

  defp parse_and_validate(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp normalize_url(%URI{} = uri) do
    uri
    |> Map.put(:scheme, String.downcase(uri.scheme))
    |> Map.put(:host, String.downcase(uri.host))
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  # Resolves `host` and rejects loopback, private and link-local addresses — in
  # their IPv6 forms too, including IPv6 addresses that merely *embed* an IPv4 one
  # (IPv4-mapped `::ffff:0:0/96`, IPv4-compatible `::/96`, 6to4, Teredo), which
  # route to that IPv4 address and must answer exactly as it would — plus a
  # short list of hostnames that are dangerous even before DNS gets involved
  # (`localhost`, the GCP/AWS metadata hostname). Resolution failure is treated as
  # `:ok` rather than `:blocked_host` — an unresolvable host is a network error, not a
  # security decision, and the fetcher will fail on it naturally (as
  # `:fetch_failed`) without this guard pretending to know why.
  #
  # Public (`@doc false`) since the Overpass adapter landed, per
  # docs/research/activity-discovery.md trap J: a URL that comes *back* from a
  # provider is attacker-influenceable input, and every Discovery adapter must run
  # it through this same check before it enters a `Result` — one SSRF allowlist,
  # never two that drift. Behaviour for this module's own callers is unchanged;
  # `test/consensus/discovery/provider/overpass_test.exs` pins the export so a
  # tidy-up cannot silently re-privatise it and un-guard every adapter.
  @doc false
  @spec check_host(String.t()) :: :ok | {:error, :blocked_host}
  def check_host(host) do
    downcased = String.downcase(host)

    cond do
      downcased in @blocked_hostnames ->
        {:error, :blocked_host}

      ip = literal_ip(downcased) ->
        if blocked_ip?(ip), do: {:error, :blocked_host}, else: :ok

      true ->
        case :inet.gethostbyname(String.to_charlist(downcased)) do
          {:ok, {:hostent, _name, _aliases, _addrtype, _length, addresses}} ->
            if Enum.any?(addresses, &blocked_ip?/1), do: {:error, :blocked_host}, else: :ok

          {:error, _reason} ->
            :ok
        end
    end
  end

  defp literal_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  # 0.0.0.0/8 ("this host on this network"): connecting to 0.0.0.0 reaches
  # loopback on Linux and macOS, so it is 127.0.0.1 wearing another name.
  defp blocked_ip?({0, _, _, _}), do: true

  # IPv6 loopback (::1) and unspecified (::).
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # An IPv6 address that embeds an IPv4 address routes to that IPv4 address, so
  # it must answer exactly as the embedded address would — before these clauses,
  # `[::ffff:169.254.169.254]` walked straight past every IPv4 rule above. In
  # order: IPv4-mapped (`::ffff:0:0/96`, the one every dual-stack socket layer
  # actually honours), the deprecated IPv4-compatible (`::/96`), and 6to4
  # (`2002::/16`, the IPv4 in the next 32 bits).
  defp blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: blocked_ip?(embedded_ipv4(hi, lo))
  defp blocked_ip?({0, 0, 0, 0, 0, 0, hi, lo}), do: blocked_ip?(embedded_ipv4(hi, lo))
  defp blocked_ip?({0x2002, hi, lo, _, _, _, _, _}), do: blocked_ip?(embedded_ipv4(hi, lo))

  # NAT64 well-known prefix (64:ff9b::/96, RFC 6052): a synthesized address
  # that routes to the embedded IPv4 target in the last 32 bits, same
  # reasoning as the mapped/compatible/6to4 clauses above.
  defp blocked_ip?({0x0064, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: blocked_ip?(embedded_ipv4(hi, lo))

  # NAT64 local-use prefix (64:ff9b:1::/48, RFC 8215): the RFC 6052 companion
  # for networks that translate toward private/shared address space precisely
  # because the well-known prefix must not — i.e. the deployments MOST likely
  # to route a synthesized address at an internal target. Embedded IPv4 in the
  # last 32 bits, checked exactly like the well-known prefix above.
  defp blocked_ip?({0x0064, 0xFF9B, 0x0001, _, _, _, hi, lo}),
    do: blocked_ip?(embedded_ipv4(hi, lo))

  # Teredo (2001:0::/32) embeds two IPv4 addresses: the server's in words 3–4
  # and the client's — bit-inverted — in words 7–8. Either one being private
  # marks a tunnel toward exactly what this guard exists to keep away from.
  defp blocked_ip?({0x2001, 0, server_hi, server_lo, _, _, client_hi, client_lo}) do
    blocked_ip?(embedded_ipv4(server_hi, server_lo)) or
      blocked_ip?(embedded_ipv4(Bitwise.bxor(client_hi, 0xFFFF), Bitwise.bxor(client_lo, 0xFFFF)))
  end

  defp blocked_ip?(ip) when tuple_size(ip) == 8 do
    # fc00::/7 (unique local), fe80::/10 (link-local), and fec0::/10
    # (deprecated site-local, RFC 3879 — deprecated, not gone: still routable
    # on a network that never migrated off it).
    first = elem(ip, 0)
    first in 0xFC00..0xFDFF or first in 0xFE80..0xFEBF or first in 0xFEC0..0xFEFF
  end

  defp blocked_ip?(_ip), do: false

  # Two 16-bit IPv6 words carrying an embedded IPv4 address, re-expressed as the
  # 4-tuple the IPv4 clauses above understand.
  defp embedded_ipv4(hi, lo) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end

  ## Description truncation — 140 characters, on a word boundary

  defp truncate_description(nil), do: nil

  defp truncate_description(text) do
    if String.length(text) <= @description_max_length do
      text
    else
      text
      |> String.slice(0, @description_max_length)
      |> truncate_to_word_boundary()
    end
  end

  defp truncate_to_word_boundary(slice) do
    case Regex.run(~r/\A.*\s/us, slice) do
      [match] -> String.trim_trailing(match)
      nil -> slice
    end
  end
end
