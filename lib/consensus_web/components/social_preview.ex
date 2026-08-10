defmodule ConsensusWeb.SocialPreview do
  @moduledoc """
  The OpenGraph / Twitter-card block in `<head>` — what a Consensus link looks like when
  somebody pastes it into a group chat.

  This is the other half of `Consensus.LinkPreview`. That module *reads* somebody else's
  OpenGraph tags so an organizer can paste a restaurant URL into their pool; this one
  *writes* ours, so the share link the whole product funnels through unfurls as a card
  instead of a bare URL. Frame `1d-0`
  (`docs/design/screens/1d-0-in-app-preview-paste-ready-copy.html`) draws that card as the
  thing the organizer is promised on `04 share`, and until now the promise was empty: the
  app emitted no `og:` tags at all, so every paste rendered as naked text.

  ## The image is static, and per-group detail rides in the text

  `og:image` is one pre-rendered 1200×630 asset for the whole app
  (`priv/static/images/og/consensus-og.png`), rendered from the "Consensus - Social
  Preview" file in the linked Claude Design project. The alternative — a
  `GET /join/:slug/og.png` that burns the group's title and spot count into the pixels —
  needs an SVG rasterizer in the release image and a cache, on a single Fly machine
  holding a SQLite write lock. It buys nothing a chat client does not already show:
  every unfurler renders `og:title` and `og:description` as text *beside* the image, which
  is exactly where frame `1d-0` puts the group's own words. See D-050.

  ## Why no deadline in `og:description`

  `06`'s pill and `04`'s invite card both say "closes thu 6pm", and it is tempting to
  repeat here. Two reasons not to:

    * **There is no timezone on the dead render.** This app carries no timezone database
      (D-031) — local time comes from a `tz_offset` LiveView connect param, and a crawler
      never connects a socket. The clock would be computed at UTC and a Thursday 6pm ET
      deadline would unfurl as "closes fri 10pm".
    * **Unfurl caches are sticky.** Slack, iMessage and WhatsApp cache a card for hours to
      days, keyed on the URL. A countdown baked into that cache is wrong shortly after it
      is written and cannot be corrected.

  So the description carries what stays true for the life of the link: who called the
  vote, how many spots, and that it costs one tap and no account.
  """

  use ConsensusWeb, :html

  @site_name "Consensus"

  # Deliberately the design's own headline and sub-line, so the card's text and its image
  # say the same thing.
  @default_title "Consensus — Decide and Dine"
  @default_description "Put the options up, share one link, everyone ranks. No app, no account."

  @image_path "/images/og/consensus-og.png"
  @image_width "1200"
  @image_height "630"
  @image_alt "A phone showing a live Consensus vote — three dinner options with vote bars, one vetoed — beside the words “Decide and Dine”."

  # What the platforms actually truncate at. Clamping here rather than letting them do it
  # means the ellipsis lands where we chose and a pathological group title cannot push the
  # rest of the card out of the render.
  @title_limit 70
  @description_limit 200

  @doc """
  Renders the whole `<head>` social block.

  Every attribute is optional and falls back to the app-wide default, so a screen that
  says nothing still unfurls correctly — including the two error pages, which reach this
  through `config :consensus, ConsensusWeb.ErrorHTML`'s root layout and have no assigns of
  their own.
  """
  attr :title, :string,
    default: nil,
    doc: "og:title. Not the `<title>` — no “ · Consensus” suffix."

  attr :description, :string, default: nil, doc: "og:description and <meta name=description>."
  attr :url, :string, default: nil, doc: "Absolute canonical URL. Overrides `current_path`."

  attr :current_path, :string,
    default: nil,
    doc: "`@current_path` from `ConsensusWeb.CurrentPath`. Used to derive the canonical URL."

  def meta_tags(assigns) do
    assigns =
      assigns
      |> assign(:title, clamp(assigns.title || @default_title, @title_limit))
      |> assign(
        :description,
        clamp(assigns.description || @default_description, @description_limit)
      )
      |> assign(:url, assigns.url || canonical_url(assigns.current_path))
      |> assign(:image, image_url())
      |> assign(:site_name, @site_name)
      |> assign(:image_width, @image_width)
      |> assign(:image_height, @image_height)
      |> assign(:image_alt, @image_alt)

    ~H"""
    <meta name="description" content={@description} />
    <link rel="canonical" href={@url} />

    <meta property="og:type" content="website" />
    <meta property="og:site_name" content={@site_name} />
    <meta property="og:title" content={@title} />
    <meta property="og:description" content={@description} />
    <meta property="og:url" content={@url} />
    <meta property="og:image" content={@image} />
    <meta property="og:image:width" content={@image_width} />
    <meta property="og:image:height" content={@image_height} />
    <meta property="og:image:alt" content={@image_alt} />

    <%!-- `summary_large_image` is what makes the 1200×630 render full-bleed rather than as
          a 120px thumbnail. Title, description and image all fall back to the `og:` tags
          above, so only the card type and the alt text need restating. --%>
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:image:alt" content={@image_alt} />
    """
  end

  @doc """
  The absolute URL of the shared `og:image`.

  Absolute because every unfurler resolves `og:image` from its own host, not from the page
  — a root-relative path is simply dropped. `Endpoint.url()` is the same idiom
  `ConsensusWeb.GroupLive.Share` builds its join link with, and `~p` on a path under
  `ConsensusWeb.static_paths/0` appends the cache-busting `?vsn=` digest in prod, which is
  what lets a redesigned card escape a chat client's sticky unfurl cache.
  """
  def image_url, do: ConsensusWeb.Endpoint.url() <> ~p"/images/og/consensus-og.png"

  @doc "The app-wide defaults, exposed so tests can assert against one source of truth."
  def defaults,
    do: %{title: @default_title, description: @default_description, image_path: @image_path}

  # `@current_path` carries the query string (`ConsensusWeb.CurrentPath.path_with_query/1`),
  # and a canonical must not: every standing page is reachable as
  # `/about?return_to=/groups/3/options`, so honouring the query would mint a distinct
  # canonical — and a distinct unfurl-cache key — per screen the footer was tapped from.
  # A screen with a real canonical of its own passes `url` and skips this entirely.
  defp canonical_url(nil), do: ConsensusWeb.Endpoint.url()

  defp canonical_url(path) when is_binary(path) do
    ConsensusWeb.Endpoint.url() <> (path |> String.split("?") |> hd())
  end

  # Collapses newlines and runs of whitespace before measuring. Group titles are free text
  # (CLAUDE.md invariant 11 — the changeset is the only length limit, and it is
  # generous), and a `content=` attribute holding a literal newline is both ugly and read
  # inconsistently across unfurlers.
  defp clamp(text, limit) do
    text = text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) > limit do
      String.trim_trailing(String.slice(text, 0, limit - 1)) <> "…"
    else
      text
    end
  end
end
