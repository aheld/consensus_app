defmodule Consensus.LinkPreview.JsonLd do
  @moduledoc """
  Reads `schema.org` JSON-LD out of a page's `<script type="application/ld+json">`
  blocks, so a pasted link that carries structured data produces a better card than
  its meta tags alone would.

  This is F3 of the Assisted Add brief and Stage 2 of
  `docs/research/activity-discovery.md` — deliberately independent of
  `Consensus.Discovery`. It adds no vendor, no key, no licence, no column and no
  dependency: the page has already been fetched for its OpenGraph tags, and this
  reads a second thing out of the same bytes.

  ## Where it sits in the precedence order

  `Consensus.LinkPreview.Fetcher.Req.extract_metadata/2` resolves each field as:

      og:<field>  →  JSON-LD  →  plain HTML (<title>, meta[name=description], link[rel=image_src])

  JSON-LD is a **fallback below OpenGraph, not a replacement for it**. A page whose
  `og:` tags already produce a good card is bit-for-bit unaffected by this module,
  which is what makes the change strictly additive. It outranks the plain-HTML
  fallbacks because those are the weakest signal on exactly the pages structured data
  is best on: `<title>` on a recipe page is typically `"Recipe Name | Site Name"`
  where JSON-LD's `name` is just `"Recipe Name"`.

  ## Which nodes are eligible

  `@content_types` is an ordered allowlist, and it is **data, read by index** — there
  is no per-type code, in the same spirit as the `Consensus.Discovery` provider
  registry (CLAUDE.md product invariant 2). A node qualifies only if its `@type` is on
  that list; when several qualify, the earliest entry wins.

  The allowlist is deliberately not "anything with a name". Most pages also carry
  `Organization`, `WebSite` and `BreadcrumbList` nodes whose `name` is the *site's*
  name — adopting one of those would make the card worse than the `<title>` fallback
  it displaced. The list covers the four things the research names (recipes, movies,
  books, events) plus this app's own four verticals as a venue's page describes
  itself, with generic parents like `LocalBusiness` and `CreativeWork` ranked last
  because they are real but weak signals.

  ## Failure is silence

  Any malformed block, unparseable JSON, unexpected shape, or exception is swallowed
  and returns empty metadata — never an error, and never a raise into the caller.
  This is not defensive habit, it is the central requirement: the JSON-LD on an
  arbitrary third-party page is attacker-influenceable input arriving on a path that
  **already worked**, so a parse failure here must cost the organizer nothing. A
  crash that propagated would turn a page with perfectly good `og:` tags into
  `{:error, :fetch_failed}` — a regression caused entirely by an optional enhancement.
  """

  require Logger

  @script_regex ~r/<script\b([^>]*)>(.*?)<\/script>/is

  # Bounds on attacker-controlled structure. The response body is already capped at
  # 512KB by the fetcher, so these are belt-and-braces against a page that spends all
  # of it on pathological nesting or block count rather than content.
  @max_blocks 20
  @max_depth 12

  # Ordered by descending specificity: the earliest matching entry wins. See the
  # moduledoc for why this is an allowlist rather than "any node with a name".
  @content_types [
    # The four the research names — the reason this stage exists at all.
    "Recipe",
    "Movie",
    "Book",
    # Event, then the subtypes that actually appear on ticketing and listings pages.
    "ScreeningEvent",
    "MusicEvent",
    "TheaterEvent",
    "FoodEvent",
    "SportsEvent",
    "ExhibitionEvent",
    "Festival",
    "SocialEvent",
    "BusinessEvent",
    "Event",
    # Movie-adjacent.
    "TVEpisode",
    "TVSeries",
    "VideoObject",
    # This app's own verticals — the D-052 registry's four activity types, as a
    # venue's own page describes itself.
    "Restaurant",
    "FoodEstablishment",
    "BarOrPub",
    "Bar",
    "CafeOrCoffeeShop",
    "Brewery",
    "Winery",
    "NightClub",
    "BowlingAlley",
    "MovieTheater",
    # Generic parents last: a real signal, but a weak one.
    "LocalBusiness",
    "Product",
    "NewsArticle",
    "BlogPosting",
    "Article",
    "CreativeWork"
  ]

  @type_priority @content_types |> Enum.with_index() |> Map.new()

  @type metadata :: %{
          title: String.t() | nil,
          description: String.t() | nil,
          image_url: String.t() | nil,
          site_name: String.t() | nil
        }

  @doc """
  Extracts metadata from the best `schema.org` node in `html`.

  Every field is independently nil-able, and a page with no JSON-LD, unparseable
  JSON-LD, or only ineligible node types returns all-`nil` rather than an error.

  Values come back **raw**: not entity-decoded, not resolved against a base URL, not
  truncated. `Consensus.LinkPreview.Fetcher.Req` applies all three, so the OpenGraph
  path and this one normalise through exactly the same code.
  """
  @spec extract(binary()) :: metadata()
  def extract(html) when is_binary(html) do
    html
    |> ld_json_blocks()
    |> Enum.flat_map(&decode/1)
    |> Enum.flat_map(&flatten(&1, 0))
    |> best_node()
    |> to_metadata()
  rescue
    exception ->
      Logger.warning(
        "Consensus.LinkPreview.JsonLd: extraction raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      empty()
  catch
    kind, reason ->
      Logger.warning(
        "Consensus.LinkPreview.JsonLd: extraction exited: #{inspect({kind, reason})}"
      )

      empty()
  end

  ## Locating and decoding the blocks

  defp ld_json_blocks(html) do
    @script_regex
    |> Regex.scan(html)
    |> Enum.filter(fn [_whole, attrs, _body] -> ld_json_type?(attrs) end)
    |> Enum.take(@max_blocks)
    |> Enum.map(fn [_whole, _attrs, body] -> body end)
  end

  # The media type may carry parameters (`application/ld+json; charset=utf-8`) and is
  # case-insensitive, so this matches on the prefix of the decoded attribute rather
  # than on equality with the bare type.
  defp ld_json_type?(attrs) do
    case Regex.run(~r/\btype\s*=\s*(["'])(.*?)\1/is, attrs) do
      [_, _quote, value] ->
        value |> String.trim() |> String.downcase() |> String.starts_with?("application/ld+json")

      _ ->
        false
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, value} -> [value]
      {:error, _reason} -> []
    end
  end

  ## Flattening to a list of candidate nodes
  #
  # Handles the three shapes that actually occur: a bare object, a top-level array of
  # objects, and the `@graph` wrapper. It deliberately does NOT recurse into arbitrary
  # nested properties — descending into `itemListElement` or `mainEntity` surfaces
  # breadcrumb fragments and related-content stubs that score as eligible types while
  # describing something other than the page.

  defp flatten(_value, depth) when depth > @max_depth, do: []

  defp flatten(list, depth) when is_list(list) do
    Enum.flat_map(list, &flatten(&1, depth + 1))
  end

  defp flatten(%{} = node, depth) do
    case Map.get(node, "@graph") do
      nil -> [node]
      graph -> [node | flatten(graph, depth + 1)]
    end
  end

  defp flatten(_other, _depth), do: []

  ## Choosing the best node

  defp best_node(nodes) do
    nodes
    |> Enum.map(fn node -> {priority(node), node} end)
    |> Enum.reject(fn {priority, _node} -> is_nil(priority) end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.min_by(fn {priority, _node} -> priority end) |> elem(1)
    end
  end

  # `@type` is a string on most pages and a list on some ("@type": ["Restaurant",
  # "LocalBusiness"]); when it is a list, the node scores as its most specific member.
  defp priority(%{"@type" => type}) do
    type
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&type_index/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      indexes -> Enum.min(indexes)
    end
  end

  defp priority(_node), do: nil

  # Tolerates the fully-qualified and prefixed spellings of a type — "Recipe",
  # "http://schema.org/Recipe" and "schema:Recipe" are all the same type, and all
  # three appear in the wild.
  defp type_index(type) do
    bare =
      type
      |> String.trim()
      |> String.split("/")
      |> List.last()
      |> String.split(":")
      |> List.last()

    Map.get(@type_priority, bare)
  end

  ## Pulling fields off the chosen node

  defp to_metadata(nil), do: empty()

  defp to_metadata(node) do
    %{
      title: string_value(Map.get(node, "name")),
      description: string_value(Map.get(node, "description")),
      image_url: image_url(node),
      site_name: site_name(node)
    }
  end

  defp empty, do: %{title: nil, description: nil, image_url: nil, site_name: nil}

  # `image` is specified as one of: a URL string, an ImageObject, or an array of
  # either. `thumbnailUrl` is the documented fallback and is often the only one
  # present on video and event pages.
  defp image_url(node) do
    first_url(Map.get(node, "image")) || first_url(Map.get(node, "thumbnailUrl"))
  end

  defp first_url(value) when is_binary(value), do: string_value(value)

  defp first_url(%{} = object) do
    string_value(Map.get(object, "url")) || string_value(Map.get(object, "contentUrl"))
  end

  defp first_url(list) when is_list(list), do: Enum.find_value(list, &first_url/1)

  defp first_url(_other), do: nil

  # `publisher` is an Organization on most pages and occasionally a bare string.
  defp site_name(node) do
    case Map.get(node, "publisher") do
      publisher when is_binary(publisher) -> string_value(publisher)
      %{} = publisher -> string_value(Map.get(publisher, "name"))
      _other -> nil
    end
  end

  # Guards against the field being present but not a string — `"name": {...}` and
  # `"description": 42` both occur, and both must read as absent rather than crash
  # or land a stringified map in the card.
  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(_other), do: nil
end
