defmodule Consensus.Discovery.Result do
  @moduledoc """
  One transient search result from a `Consensus.Discovery.Provider` — never
  persisted as such (docs/research/activity-discovery.md §4.3). Accepting a result
  means writing an ordinary `Consensus.Activities.Activity` from its `:name` and
  `:website_url`; everything else here dies with the socket that displayed it.

  That URL-only retention boundary is the licence firewall the research settles on:
  a schema that can only hold name/description/image URL/source URL has nowhere to
  put a rating, a price band or a lat/lon, so it cannot violate any provider's
  storage terms.

  ## Fields

    * `:name` — the venue/thing's canonical name. Becomes `Activity.name` on accept.
    * `:website_url` — becomes `Activity.source_url`; `Consensus.LinkPreview` then
      fills photo/description exactly as it does for a pasted link. May be `nil`
      (an OSM node with no `website` tag) — such a result can still be shown, it
      just enriches nothing.
    * `:source` — an atom naming where this came from (e.g. `:osm`). For
      attribution, not for branching.
    * `:external_ref` — opaque provider ref (e.g. `"node/1234567"`). Displayed
      never; persisted never in this stage.
    * `:chips` — `[{label, value}]` display-only decorations (e.g.
      `{"cuisine", "thai"}`). Dies with the socket.
    * `:address` — a human-readable street address string for the suggestion row.
      **A deliberate extension of research §4.3**: the assisted-add brief
      (docs/design/assisted-add-ux-brief.md §4) specifies the suggestion row as
      "venue name + street address", with the address as the disambiguator between
      up to three matches. Display-only, never persisted — same lifetime as
      `:chips`.
  """

  @enforce_keys [:name, :source]
  defstruct [:name, :website_url, :source, :external_ref, :chips, :address]

  @type t :: %__MODULE__{
          name: String.t(),
          website_url: String.t() | nil,
          source: atom(),
          external_ref: String.t() | nil,
          chips: [{String.t(), String.t()}] | nil,
          address: String.t() | nil
        }
end
