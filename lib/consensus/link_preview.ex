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

  # Resolves `host` and rejects loopback, private and link-local addresses, plus a
  # short list of hostnames that are dangerous even before DNS gets involved
  # (`localhost`, the GCP/AWS metadata hostname). Resolution failure is treated as
  # `:ok` rather than `:blocked_host` — an unresolvable host is a network error, not a
  # security decision, and the fetcher will fail on it naturally (as
  # `:fetch_failed`) without this guard pretending to know why.
  defp check_host(host) do
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
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp blocked_ip?(ip) when tuple_size(ip) == 8 do
    first = elem(ip, 0)
    first in 0xFC00..0xFDFF
  end

  defp blocked_ip?(_ip), do: false

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
