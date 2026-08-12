defmodule Consensus.LinkPreview.Fetcher do
  @moduledoc """
  Behaviour for the single HTTP request `Consensus.LinkPreview.fetch/1` needs per hop.

  Configured via `Application.get_env(:consensus, Consensus.LinkPreview)[:fetcher]` so
  tests can inject a module-based stub (no Mox in this project). `config/config.exs`
  points this at `Consensus.LinkPreview.Fetcher.Req`; `config/test.exs` points it at a
  stub defined in `test/consensus/link_preview_test.exs`.

  Implementations must **not** follow redirects themselves — `Consensus.LinkPreview`
  re-runs the SSRF guard on every hop, so it drives the redirect loop and expects a
  bare 3xx response back with a `location` header rather than an already-followed
  chain.
  """

  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          url: String.t()
        }

  @doc """
  Issues one GET request to `url` and returns the raw response — no redirect
  following, no interpretation of `status`. `opts` carries `:connect_timeout_ms`,
  `:receive_timeout_ms` and `:max_body_bytes`; a real implementation is expected to
  honour all three.
  """
  @callback get(url :: String.t(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end

defmodule Consensus.LinkPreview.Fetcher.Req do
  @moduledoc """
  The real `Consensus.LinkPreview.Fetcher`, backed by `Req`.

  Also houses the HTML metadata parser (`extract_metadata/2`), which `Consensus.
  LinkPreview` calls directly regardless of which fetcher is configured — parsing is
  not part of the behaviour, only fetching is. `LazyHTML` is only available in `:test`
  (it ships with Phoenix's test deps), so this app cannot rely on it in production;
  meta tags are regular enough that a small hand-rolled regex parser is deliberate
  here rather than a missing dependency. It tolerates both attribute orders
  (`property` before or after `content`) and either quote style, because it looks up
  each attribute independently against the whole tag rather than assuming a fixed
  order.

  Since F3, each field resolves through a three-source chain — OpenGraph, then
  `schema.org` JSON-LD (`Consensus.LinkPreview.JsonLd`), then the plain HTML tag —
  and the winner is the first source that yields a *non-blank* value, not merely a
  present one. That distinction is load-bearing: `<meta property="og:title"
  content="">` returns `""`, which is truthy in Elixir, so an `||` chain would let an
  empty tag suppress both fallbacks and produce a card with no title at all.

  Sharing this file with the behaviour (rather than a `fetcher/req.ex`) is a
  deliberate, narrow exception to "one module per file": the two are never used
  independently of each other, and nothing here nests one `defmodule` inside another.
  """

  @behaviour Consensus.LinkPreview.Fetcher

  alias Consensus.LinkPreview.JsonLd

  @meta_tag_regex ~r/<meta\b[^>]*>/i
  @link_tag_regex ~r/<link\b[^>]*>/i
  @title_tag_regex ~r/<title[^>]*>(.*?)<\/title>/is
  @entity_regex ~r/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/

  @named_entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  @impl true
  def get(url, opts) do
    max_bytes = Keyword.fetch!(opts, :max_body_bytes)

    Req.new(
      url: url,
      redirect: false,
      retry: false,
      connect_options: [timeout: Keyword.fetch!(opts, :connect_timeout_ms)],
      receive_timeout: Keyword.fetch!(opts, :receive_timeout_ms)
    )
    |> Req.get(into: capping_collector(max_bytes))
    |> case do
      {:ok, resp} ->
        {:ok,
         %{
           status: resp.status,
           headers: normalize_headers(resp.headers),
           body: resp.body || "",
           url: url
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A response body is capped by halting the stream once the accumulated size passes
  # `max_bytes` rather than by reading the whole thing and trimming after — an
  # attacker-controlled page must never be able to make this GenServer-free path hang
  # on or hold a multi-gigabyte body in memory.
  defp capping_collector(max_bytes) do
    fn {:data, data}, {req, resp} ->
      body = (resp.body || "") <> data

      if byte_size(body) > max_bytes do
        {:halt, {req, %{resp | body: binary_part(body, 0, max_bytes)}}}
      else
        {:cont, {req, %{resp | body: body}}}
      end
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {name, values} -> {name, Enum.join(List.wrap(values), ", ")} end)
  end

  @doc """
  Extracts metadata from `html`, resolving each field through OpenGraph, then
  `schema.org` JSON-LD, then the plain HTML tag; resolving a relative image URL
  against `base_url`; and HTML-entity-decoding every text field.

  Returns raw (untruncated) values — `Consensus.LinkPreview` applies the 140-character
  description cap, since that is a UI constraint, not a parsing one. Any field that
  cannot be found, or that is blank once decoded, comes back `nil`.
  """
  @spec extract_metadata(binary(), String.t()) :: %{
          title: String.t() | nil,
          description: String.t() | nil,
          image_url: String.t() | nil,
          site_name: String.t() | nil
        }
  def extract_metadata(html, base_url) when is_binary(html) do
    meta_tags = tags(html, @meta_tag_regex)
    link_tags = tags(html, @link_tag_regex)
    json_ld = JsonLd.extract(html)

    title =
      first_present([
        meta_content(meta_tags, "property", "og:title"),
        json_ld.title,
        title_tag(html)
      ])

    description =
      first_present([
        meta_content(meta_tags, "property", "og:description"),
        json_ld.description,
        meta_content(meta_tags, "name", "description")
      ])

    # Resolved per candidate rather than after the winner is picked, so a present but
    # unusable `og:image` (an unresolvable reference, or a non-http scheme) falls
    # through to JSON-LD instead of blanking the card's image.
    image_url =
      Enum.find_value(
        [
          meta_content(meta_tags, "property", "og:image"),
          json_ld.image_url,
          link_href(link_tags, "image_src")
        ],
        fn value ->
          value |> decode_entities() |> presence() |> resolve_image_url(base_url)
        end
      )

    site_name =
      first_present([
        meta_content(meta_tags, "property", "og:site_name"),
        json_ld.site_name
      ])

    %{title: title, description: description, image_url: image_url, site_name: site_name}
  end

  # The first candidate that is non-blank once decoded wins. See the moduledoc for why
  # this is not an `||` chain.
  defp first_present(values) do
    Enum.find_value(values, fn value -> value |> decode_entities() |> presence() end)
  end

  defp tags(html, regex), do: regex |> Regex.scan(html) |> List.flatten()

  defp title_tag(html) do
    case Regex.run(@title_tag_regex, html) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  defp meta_content(tags, attr, value) do
    Enum.find_value(tags, fn tag ->
      if attr_equals?(tag, attr, value), do: tag_attr(tag, "content")
    end)
  end

  defp link_href(tags, rel_value) do
    Enum.find_value(tags, fn tag ->
      if attr_equals?(tag, "rel", rel_value), do: tag_attr(tag, "href")
    end)
  end

  defp attr_equals?(tag, attr, value) do
    case tag_attr(tag, attr) do
      nil -> false
      found -> String.downcase(found) == value
    end
  end

  defp tag_attr(tag, name) do
    case Regex.run(~r/\b#{name}\s*=\s*(["'])(.*?)\1/is, tag) do
      [_, _quote, value] -> value
      _ -> nil
    end
  end

  defp decode_entities(nil), do: nil

  defp decode_entities(text) do
    Regex.replace(@entity_regex, text, fn whole, entity -> decode_entity(entity, whole) end)
  end

  defp decode_entity("#x" <> hex, whole) do
    case Integer.parse(hex, 16) do
      {code, ""} -> codepoint(code, whole)
      _ -> whole
    end
  end

  defp decode_entity("#" <> dec, whole) do
    case Integer.parse(dec, 10) do
      {code, ""} -> codepoint(code, whole)
      _ -> whole
    end
  end

  defp decode_entity(name, whole), do: Map.get(@named_entities, name, whole)

  defp codepoint(code, whole) when code in 0..0x10FFFF do
    <<code::utf8>>
  rescue
    ArgumentError -> whole
  end

  defp codepoint(_code, whole), do: whole

  # Resolves an image reference against the page URL and admits only absolute
  # http/https results. Both the OpenGraph and the JSON-LD candidate go through this
  # one function on purpose: an image URL is the only field here that a page can put
  # into an attribute the browser will act on, and two near-identical sanitizers that
  # drift apart is the failure mode `Consensus.LinkPreview.check_host/1` already
  # carries a comment about. A protocol-relative `//cdn.example.com/x.jpg` still
  # resolves normally; `javascript:`, `data:` and `file:` references do not survive.
  defp resolve_image_url(nil, _base), do: nil

  defp resolve_image_url(url, base) do
    merged = base |> URI.merge(url) |> URI.to_string()

    case URI.parse(merged) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        merged

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  defp presence(nil), do: nil

  defp presence(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
