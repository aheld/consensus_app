# Activity discovery — a generic search layer for `02 add options`

**Status:** research, not ratified. Nothing here is implemented. Every price, rate limit and licence
clause carries a source URL and the date it was read. Where a claim could not be verified at its
primary source it says **unverified** and says what was tried.

**Date of research:** 2026-08-09. Pricing pages change; re-read before budgeting.

**Review pass, 2026-08-09 (same day, second reader).** Nineteen pricing/licence claims were re-fetched
at their primary sources. Most held exactly. Corrections are marked inline with ~~strikethrough~~ and
a `corrected 2026-08-09` note so the movement is visible rather than silently overwritten. The three
that mattered:

- **Brave's attribution is optional, not required, and the $5 monthly credit is not conditioned on
  it.** The original text had this backwards. §3 trap B, and two rows of §2.
- **Foursquare's own pricing page contradicts itself** on the free allowance (500 vs 10,000). The
  `~$7.50 at 1,000 calls` figure is one of two defensible readings, not a fact. §2, §6.
- **Yelp §5(a)/§5(b) and Google's "must be shown on a Google Map" clause are now verified at source**,
  not researcher-reported. Both *strengthen* the rejections. §3 traps A and D.

Two repo-side claims also had to be repaired, and both are the kind that only surface when someone
tries to build from the document: **trap J prescribed calling `LinkPreview.check_host/1`, which is
private** (`defp`, line 212), and **§4.3's behaviour was missing the callback §4.1 depends on**, which
would have pushed a per-type conditional into the LiveView — invariant 12 broken one layer above the
place the document spends a whole section guarding. Both are patched in place. A new **trap L** was
added for a rate-limit figure the draft attributed to Overpass's published policy, which does not
publish it.

Neither the recommendation nor any rejection changes; several rejections got *stronger*. Section 5's
time estimates change materially — the "one day" first stage was not one day, and a genuinely
day-sized **Stage 0** has been split out ahead of it. See the note there.

---

## 1. Recommendation

Build **`Consensus.Discovery`** as a sibling of `Consensus.LinkPreview`: a config-map registry of
adapters keyed by `activity_type` string, a behaviour those adapters implement, and a **transient**
result struct that carries only a **name and a website URL**. Adding a discovered result creates an
ordinary `Activity` with `name` and `source_url`, and the *existing* `LinkPreview` `start_async`
path — unchanged, not extended — fills in `description` and `image_url`. **Zero new schema columns
in stage 1.** The data source is OpenStreetMap: the public **Overpass API** on day one because it is
an HTTP call and nothing else, then a **local Overture Maps places extract in SQLite** (17.6 MB per
metro, sub-millisecond, no network, no rate limit, permissive licence) as the very next stage, which
the adapter contract makes a config change rather than a rewrite. Location comes from a **typed
neighbourhood geocoded once by Nominatim into a bounding box and stored on the group, not on the
person**. **Cost: $0.00/month at 100 searches, $0.00/month at 1,000, $0.00/month at 100,000** —
there is no metered vendor anywhere in the recommended path, no API key, no card on file, and
therefore no bill that grows when the product succeeds. Every commercial place API is rejected, and
**not on price — on licence**: Google, Yelp, Foursquare, Mapbox and TripAdvisor all forbid storing
the fields this product's durable `activities` row is made of, which is an architectural
incompatibility, not a cache-TTL parameter.

**If you read nothing else, read §3.** The licence traps are the part that invalidates otherwise
sensible designs.

---

## 2. Comparison

Cost columns assume this product's real volume. "~100/mo" is a handful of searches a day; "~1,000/mo"
is roughly ten times the current plausible ceiling.

| Option | ~100 searches/mo | ~1,000 searches/mo | Caching allowed? | Attribution required? | Non-restaurants? | Ops burden |
|---|---|---|---|---|---|---|
| **OSM via Overpass (public)** ✅ *stage 1* | **$0** | **$0** | Yes, unlimited (ODbL) | Yes — "© OpenStreetMap contributors" + link to `/copyright` | Yes — `leisure=bowling_alley`, `amenity=cinema`, `amenity=bar`, `leisure=park` | Low: one HTTP call. But a shared volunteer endpoint, ~2 slots per IP *(observed, not published — see §3 trap L)*, measured failures |
| **Overture Places → local SQLite** ✅ *stage 3, the destination* | **$0** | **$0** | Yes, unrestricted (CDLA-Permissive-2.0 / Apache-2.0 / CC0) | Preserve licence text + Foursquare NOTICE if you redistribute the extract | Yes — 1,425 primary categories in one metro | Medium once: a build-time extract job. Then zero: no network, no key, no limit |
| **Nominatim (geocode only)** ✅ | $0 | $0 | **Caching is mandatory** | Yes (ODbL) | n/a — it resolves a place *name* to a bbox | Low, but 1 req/s and **autocomplete forbidden** |
| Photon (geocode, runner-up) | $0 | $0 | Not addressed | ODbL (OSM data) | n/a | Low. Explicitly supports typeahead. No published limit, no SLA |
| Firecrawl hosted `/search` | $0 (200 of 1,000 free credits) | $0 (2,000 credits → over free cap → **$16/mo** yearly-billed Hobby) | No restriction found in ToS | Not stated | Generic (it's web search) | Low: one call, one key. But returns *listicles*, not venues |
| Brave Search API | $0 (covered by $5/mo credit) | ~$0 (at the credit boundary) | **NO** — see trap B | ~~Yes, and the free credit is *conditional* on it~~ → **No — optional** ("Customer **may** provide attribution", ToS §4(d)); nothing conditions the credit on it *(corrected 2026-08-09)* | Generic | Low technically; a card on file that bills past the credit |
| Brave Place Search | ~$0.50 → covered | ~$5.00 *(price from Brave's own blog, 2026-07-08 — the pricing page does not list this SKU and the docs say "check your dashboard")* | **NO**, and POI IDs expire in ~8h — *verified verbatim* | ~~Yes~~ → optional, same §4(d) *(corrected 2026-08-09)* | Yes (POI categories) | Only cheap way to get the frame as drawn. Terms forbid keeping it |
| Serper | $0 (trial credits) | $0 → then **$50 minimum prepay** | No explicit clause; upstream is Google | — | Generic + `/places` | Unlicensed Google scrape; liability pushed to you |
| SerpApi | $0 (250/mo free) | $25/mo | No explicit clause | — | Generic + Local | Legal shield **excluded** from Free/Starter/Developer tiers |
| **Google Places (New)** ❌ | $0 on search SKUs | $0 on search SKUs — but ~$20/mo in *photo re-fetches* at 20 groups/mo | **NO** — place ID only | Yes: Google Maps logo, per-photo author credit | Excellent | Rejected: incompatible with a stored `activities` row |
| **Yelp Fusion** ❌ | **$229/mo** | **$229/mo** | **NO** — 24-hour ceiling on every field | Yes, prominent Yelp logo + link | Thin outside dining | Rejected: $2,748/yr floor *and* the worst terms |
| **Foursquare Places API** ❌ | $0 | ~~~$7.50~~ → **$0 or $7.50 — Foursquare's page contradicts itself** *(corrected 2026-08-09)*: the tier table reads `0 – 500 Calls · $0.00 CPM` / `501 to 100,000 · $15.00 CPM`, while the headline on the same page reads "Enjoy up to **10,000 free calls** on Pro endpoints." Do not budget either number without asking them | **NO server-side caching at all** on PAYG | Yes — credit "through either visual credit (i.e., buttons, our developer logo, etc.) or contextual credit" | Good | Rejected: forbids the cache the repo mandates. Price is moot |
| **Mapbox Search Box** ❌ | $0 | $0–$1.50 | **NO** — "temporary use" only | Yes | Yes (categories) | Rejected: storage is a separate paid SKU |
| **TripAdvisor Content API** ❌ | $0 (5,000 free) | unverified overage | **NO** — "caching, storing or indexing is not permitted" | Yes | Travel-shaped, thin locally | Rejected: card required, price unpublished |
| Self-hosted SearXNG | ~$3.32–5.92/mo (Fly) | same | You control it | — | Generic | **Rejected** — see §3, trap H |
| Self-hosted Firecrawl | $15–40/mo (Fly) | same | You control it | — | Generic | **Rejected** — needs Redis + RabbitMQ + Postgres + Playwright |
| TMDB (movies) ✅ *stage 4* | $0 | $0 | Yes, **max 6 months** | Yes, logo + exact notice | Movies/TV only | Low. **Non-commercial only** |
| `schema.org` JSON-LD in `LinkPreview` ✅ *stage 2* | **$0** | **$0** | n/a — it's the page the user pasted | None | Recipes, movies, books, events | **Lowest of anything here**: a parser change |
| Do nothing | $0 | $0 | — | — | — | Zero. See §7 |

---

## 3. The licence traps

This is the section that saves real trouble. Every trap below was read at its primary source on
2026-08-09.

### A. Google forbids saving business names. This is not a cache setting — it invalidates the schema.

> "the **place ID**, used to uniquely identify a place, is **exempt from** the caching restrictions.
> You can therefore store place ID values indefinitely."
> — [Places API policies](https://developers.google.com/maps/documentation/places/web-service/policies), read 2026-08-09

The place ID is the *only* named exemption on that page — re-verified 2026-08-09, and the re-read
turned up a **second, independent disqualifier the original draft only gestured at** in the
attribution column of §2:

> "Places API results displayed on a map must be shown on a Google Map, with proper attribution
> including the Google logo." … "When displaying Places API data without a Google Map, you must
> include the Google logo."
> — same page, read 2026-08-09

That is the "no non-Google map" rule the original §6 item 1 listed as *unverified in §14 of the
Service Specific Terms*. It is verified here, on the policies page, and it independently rejects
Google **even if** the caching problem were solved: this product renders venue cards, not a map, so
it inherits the Google-logo obligation on every discover screen and every results screen for as long
as the data is displayed. §6 item 1 has been narrowed accordingly.

The Maps Platform Terms of Service §3.2.3(a)
"No Scraping" additionally forbids you to "copy and save business names, addresses, or user reviews",
and §3.2.3(b) "No Caching" forbids caching Maps Content except as the Service Specific Terms permit.
(Researcher-reported: SST §14.3 permits caching lat/lng for up to 30 consecutive calendar days.
**Unverified at source** — `cloud.google.com/maps-platform/terms/maps-service-terms` truncated on
fetch and I could not reach §14. The place-ID-only finding above is verified and is sufficient.)

**Why this kills it here.** `Consensus.Activities.Activity` persists `name`, `description`,
`image_url` and `source_url` and re-renders them on a results page days after the vote closed. Under
Google's terms that row is a standing violation the moment it is written. The only compliant shape is
to store the place ID alone and re-fetch every displayed field on every render — which moves the cost
model from per-search to **per-page-view**, multiplied by every voter and every LiveView reconnect.
Google's stingiest allowance is Place Details Photos at 1,000 free/month, so a moderately popular
month burns it in about five groups. Google is not the safe expensive fallback; it is unusable at any
price without rebuilding the product around live fetches.

### B. Brave forbids creating a database of Search Results.

> "store, cache, or create a database of Search Results, in whole or in part, other than transient
> storage required for operation of Customer Applications"
> — [Brave Search API ToS](https://api-dashboard.search.brave.com/documentation/resources/terms-of-service), read 2026-08-09

Read literally, adding a Brave result to a pool creates a database of Search Results. The escape
hatch is precisely the architecture recommended here — persist only the **URL**, and re-derive name,
description and image from the venue's own HTML via `LinkPreview`, so the stored bytes provably came
from the venue and not from Brave. **That reading is mine, not Brave's**, and it should be put to
them in writing before any Brave-backed feature ships.

> **Corrected 2026-08-09.** The original text continued: ~~"Note also that the attribution
> ('POWERED BY BRAVE' plus logo, per §4(d)) is *conditional consideration* for the $5/month credit —
> remove the credit line from the site and the free tier stops being free."~~ **This is wrong in both
> halves.** §4(d) is permissive, not mandatory, and nothing in the ToS ties any credit, discount or
> free tier to displaying it:
>
> > "In any Customer Application integrated with the API, Customer **may** provide attribution to
> > Provider. Any such attribution shall (i) be displayed in a conspicuous manner; (ii) consist of the
> > language 'POWERED BY BRAVE' plus Provider's logo"
> > — [Brave Search API ToS](https://api-dashboard.search.brave.com/documentation/resources/terms-of-service) §4(d), re-read 2026-08-09
>
> §4(d) is a *trademark-use* clause: it does not require attribution, it constrains the form
> attribution takes **if** you choose to give it. Section 6(a) sets fees by reference to the Website
> or Order Form and does not mention attribution at all. Practical consequence: the ~~"attribution is
> the price of the credit"~~ framing must not appear in a D-050 entry or a budget, and a Brave-backed
> feature is *cheaper and simpler* than the original draft implied. It is still rejected — on the
> storage clause quoted above, which is unchanged and verified.

The POI-id half of the Brave story **is** exactly as strict as the draft said, and is now verified
verbatim rather than researcher-reported:

> "POI IDs are ephemeral and expire after approximately **8 hours**. Do not store them for later use."
> — [Place Search docs](https://api-dashboard.search.brave.com/documentation/services/place-search), read 2026-08-09

So Brave offers neither a storable record (§4(d) notwithstanding, the ToS storage clause bites) nor a
storable identifier — unlike Google, which at least grants a permanent place ID. On the retention
question Brave is *stricter* than Google, not looser.

### C. Foursquare's pay-as-you-go tier permits no server-side caching whatsoever.

> "Enterprise Customers: 24-hour local-device caching only (no server-based caching is permitted); or
> Pay as You Go & Sandbox Customers: no caching permitted."
> — [FSQ Places usage guidelines](https://docs.foursquare.com/fsq-developers-places/reference/usage-guidelines), read 2026-08-09

`Consensus.LinkPreview.Cache` is a server-side in-process cache in the supervision tree. Foursquare
forbids that shape **by name**, even for enterprise customers. This is the one case where the repo's
own mandatory-caching working agreement and a vendor's licence are in direct, unresolvable conflict.

### D. Yelp caps every field at 24 hours, and its floor is $229/month.

> Base "**$229 per month** plus **$5.91 per additional 1,000 API calls**"; Enhanced $299/month;
> Premium $643/month. "Receive **5,000 free** API calls during the 30-day trial period."
> — [Yelp data API pricing](https://business.yelp.com/data/resources/pricing/), read 2026-08-09

The pricing above was re-fetched 2026-08-09 and is exact to the dollar, including the two tiers the
draft listed without quoting: Enhanced is "$299 per month" plus "$6.57 per additional 1,000 API
calls", Premium "$643 per month" plus "$14.13 per additional 1,000 API calls". There is no free
tier — the 5,000 free calls are a 30-day evaluation on every tier.

~~Researcher-reported and not re-verified here:~~ **Verified verbatim at source, 2026-08-09**
*(upgraded from researcher-reported)* — and the actual wording is broader than the paraphrase:

> §5(a): "cache, record, pre-fetch, or otherwise store any portion of the Yelp Content for a period
> longer than twenty-four (24) hours from receipt"
> §5(b): "modify the Yelp Content, or use it to update or create your own database of business
> listing information, unless such modification is for non-commercial analysis"
> — [Yelp API Terms of Use](https://terms.yelp.com/developers/api_terms), read 2026-08-09
> (note `yelp.com/developers/api_terms` 302s to `terms.yelp.com`)

Two things the paraphrase lost. §5(a) says "**any portion** of the Yelp Content" and names
`pre-fetch` and `record` alongside `cache`, so it reaches a `%Result{}` held in an ETS entry and an
`activities` row equally — this is not a cache-TTL knob. And the draft's parenthetical "(business IDs
excepted)" was **not** found in §5(a) as fetched; treat the existence of a Google-style permanent-id
carve-out as **unverified** rather than assumed. §5(b) is an exact description of the `activities`
table. **A results page that
persists is the product's payoff (PRD invariant 5); a 24-hour ceiling forbids it.** Any note still
describing Yelp Fusion as "free up to 5,000 calls/day" is describing the pre-2024 world and would
produce a budget wrong by $2,748/year.

### E. Mapbox sells storage as a separate product, so the free path is temporary-use only.

> "all data returned by the Search Box API endpoints is only available for temporary use. If your use
> case requires storing position data, contact Mapbox sales."
> — [Search Box API docs](https://docs.mapbox.com/api/search/search-box/), read 2026-08-09

This is the most tempting trap in the set because the licence problem is **invisible in the pricing
table** — the free bands look generous. And unlike Google, Mapbox does not document *any* identifier
you are permitted to retain, so even the store-the-id-and-re-fetch fallback has no documented basis.

### F. Nominatim's usage policy inverts two normal instincts.

> "Results **must be cached** on your side. Clients sending repeatedly the same query may be
> classified as faulty and blocked."
> "**Auto-complete search** This is not yet supported by Nominatim and you must not implement such a
> service on the client side using the API."
> "No heavy uses (an absolute **maximum of 1 request per second**)."
> "Provide a valid HTTP Referer or User-Agent identifying the application (stock User-Agents as set
> by http libraries will not do)."
> — [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/), read 2026-08-09

Caching is a **requirement**, not an optimisation. And the obvious LiveView design for a location
field — `phx-change` with `phx-debounce` giving live suggestions — **is** autocomplete and is banned.
Use `phx-submit`. Nominatim also explicitly declines to answer "all objects of a type in an area" and
points you at Overpass; do not try to make one tool do both jobs.

### G. Overture's licence is per-theme and per-record. Only `places` is clean.

> Places sources: Meta, Microsoft, PinMeTo, Krick, RenderSEO, DAC, BrightQuery — "Available under
> CDLA Permissive 2.0"; Foursquare — "Available under Apache 2.0"; AllThePlaces — "Available under
> CC0 1.0".
> Base, Buildings, **Divisions**, Transportation — "© OpenStreetMap contributors. Available under the
> Open Database License".
> — [Overture attribution](https://docs.overturemaps.org/attribution/), read 2026-08-09

Keep the extract strictly to `--type=place`. The day someone adds the **divisions** theme to draw a
neighbourhood boundary, or the buildings theme for a map, ODbL share-alike comes back in through the
side door and the whole reason for choosing Overture over raw OSM evaporates.

**Two additions from the 2026-08-09 re-read.** First, there is a **sixth theme the draft omitted —
`addresses`** — and it is the one most likely to be reached for next, because a places record's
address is exactly what you would want when the name alone is ambiguous. It carries **no single
licence at all**: the attribution page lists it as permissive but per-jurisdiction, mixing CC BY 4.0,
CC0 and several national Open Government Licence variants, each with its own attribution string.
Adding `addresses` therefore means auditing a licence list per country you extract, which is a
materially worse deal than it looks. Second, and more precisely than the draft put it: `places` has
**no theme-level licence either** — the page states a licence per *source* only. The clean-licence
claim for `places` is therefore a claim that *every source present in your bbox* is one of the eight
listed permissive ones, and it is only as durable as that source list. It holds for release
2026-07-22.0; re-check the source list on every re-extract, not just the first.

### H. Self-hosted SearXNG fails **silently**, and that is worse than failing loudly.

A blocked upstream engine does not error — it lands in `unresponsive_engines` and the query returns
fewer or worse results with an HTTP 200. An organizer sees "no results for the place they know
exists" and concludes the app is broken. Fly egress is datacenter IP space, the first thing search
engines block; upstream tracks an issue titled "Google is actively blocking SearXNG instances".
Public instances are not an API either — three well-known instances were tested on 2026-08-09 and
returned a browser-verification interstitial, an immediate "Too Many Requests", and an Anubis bot
challenge respectively, i.e. **HTML that does not parse as JSON**, which is how a naive adapter
raises inside a LiveView. And the substantive objection stands even if it works perfectly: SearXNG
returns **web pages, not places**, so "best tacos in Ballard" yields Yelp search pages and listicles,
and piping those into `LinkPreview` produces a ballot option literally titled *"TOP 10 BEST Tacos
near Ballard, Seattle, WA - Yelp"* — worse than the typed name it replaced.

### I. ODbL attaches to what you *store*, and a systematic area extract crosses the line fast.

The OSMF Substantial guideline treats "less than 100 Features" as not substantial, and "100+ Features
if extraction is **non-systematic** and based on qualitative criteria" — and it explicitly aggregates
repeated small extractions. A cache of "category X in bbox Y" is systematic and area-based **by
construction**, which is exactly the pattern the guideline excludes. In practice the exposure is
thin, because share-alike bites on distributing a *database* and this app distributes a *screen*
(a Produced Work) — but the attribution obligation is unconditional. That is the strongest single
argument for moving to Overture Places (CDLA-Permissive-2.0, verified per-record) once the seam is
proven: it removes the question rather than answering it.

**Attribution is not optional and there is now somewhere to put it.** ODbL requires credit to
"OpenStreetMap" and a link making the licence clear
([openstreetmap.org/copyright](https://www.openstreetmap.org/copyright), read 2026-08-09). D-041
introduced a global header and footer, so `Places from OpenStreetMap contributors · ODbL` belongs
under the results list on the discover screen, with a permanent line in the footer.

### J. Repo-side trap: a URL that comes *back* from a provider is attacker-influenceable input.

`Activity.changeset/2`'s `validate_url/2` checks only that a value is an absolute http(s) URL with a
host. It does **not** run `LinkPreview.check_host/1`. Today that is safe only by accident: the sole
path that sets `source_url` is a paste, which is handed straight to `LinkPreview.fetch/1` and its
per-hop SSRF guard. OSM tags are crowd-edited — a `website=http://192.168.1.1/` is entirely possible.
**Rule for every adapter: a URL a provider returns goes through the same parse + `check_host` pair
before it is stored or rendered, and the fetch that enriches it is the existing `LinkPreview` path,
never a new one.** The frame draws a clickable `Menu` link, so this applies to rendering as well as
fetching.

**Correction, 2026-08-09 — the rule as written is not currently implementable.** `check_host/1` is
**private**: `lib/consensus/link_preview.ex:212` is `defp check_host(host) do`. Only the moduledoc
reference on line 14 makes it look public. So "an adapter calls `LinkPreview.check_host/1`" does not
compile, and the three ways out are not equivalent:

1. **Promote it to `@doc false` public** — one line, keeps one implementation, and is the right
   answer. The function is a pure host-string predicate with no coupling to the fetch loop.
2. **Extract it to `Consensus.LinkPreview.HostGuard`** — cleaner naming, but it is a module move
   inside the SSRF guard, which is the one piece of this code where a refactor that looks
   behaviour-preserving and isn't costs the most.
3. **Duplicate it in `Discovery`** — rejected outright. Two SSRF allowlists drift, and the one that
   drifts is the one with less test coverage.

Take (1), and pin it: a test asserting `function_exported?(Consensus.LinkPreview, :check_host, 1)`
is what stops a future tidy-up from making it private again and silently un-guarding every adapter.
Note this also means **stage 1 touches `link_preview.ex`**, which the staged plan claimed it would
not — see §5.

### K. TMDB is free only until the product earns money — and PRD invariant 5 is a revenue feature.

> Prohibited: "Cache, for longer than 6 months, any information obtained through or from TMDB or the
> TMDB APIs." Required notice: "This [website, program, service, application, product] uses TMDB and
> the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."
> — [TMDB API terms](https://www.themoviedb.org/api-terms-of-use), read and **re-verified** 2026-08-09

Both of those are exact. The third quoted fragment was not: the draft attributed ~~"does not permit
any commercial use"~~ to this page as a quotation, and **that string is not on it** *(corrected
2026-08-09)*. The operative clause is narrower and more useful, because it tells you precisely which
act triggers it:

> "Selling, leasing, or sublicensing the TMDB APIs, access to the TMDB APIs, or TMDB Content, or
> deriving revenues from the use or provision of TMDB, the TMDB APIs, or TMDB Content … is only
> permitted under a separate written agreement between You and TMDB."
> — same page, read 2026-08-09

The correction cuts both ways and is worth getting right rather than rounding to "non-commercial
only". **Narrower:** a product that merely *exists* commercially is not obviously captured — the
trigger is deriving revenue *from TMDB content or its provision*, so a paid Consensus that never
monetises the movie module has an argument the blunt reading forecloses. **Broader:** an affiliate
link on a movie card is *exactly* "deriving revenues from the use of TMDB Content", with no
ambiguity at all. So PRD invariant 5's booking/ticketing CTA remains the thing that decides it, which
was the draft's conclusion and survives — but the reasoning had to be repaired to get there, and a
D-050 entry must quote the real clause.

"Non-commercial" is defined by revenue, not traffic. PRD invariant 5 says the session ends in a
booking/ticketing CTA — precisely the shape of thing that reads as commercial. Settle this **before**
building the movie adapter. The commercial price is not published; the FAQ says email
`sales@themoviedb.org`.

### L. Overpass publishes no per-IP slot count, so stage 1's capacity budget is an observation, not a contract.

*Added on review, 2026-08-09.* The draft's §5 justified Overpass-first partly against "a **stated**
per-IP allowance of roughly 2 slots". The commons page states no such number:

> "users are expected to send a maximum of about 10000 requests per day and keep their download
> volume below about 1 GB per day."
> "Multiple slots are made available to users. The number of available slots is written in line 3
> after `Rate limit:`."
> "Requests that are denied due to the rate limit are answered with the HTTP status code 429."
> — [Overpass commons](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html), read 2026-08-09

The daily figures are exact and generous — 10,000/day is three orders of magnitude above this
product's volume, so **the daily quota is not the constraint**. The slot count is a *runtime* value
read from the instance's own status endpoint, deliberately not a published guarantee, and it is
therefore free to change without notice. Two consequences for stage 1, neither fatal but both
concrete:

- The adapter must **read 429 as a first-class, expected outcome**, not an exception — surfaced as
  the "search is busy, add it by name" path, with no retry storm. The status code is documented;
  the headroom is not.
- The observed "~2 slots, shared by every organizer on the one Fly machine" figure is the strongest
  argument in the document for stage 3, and it should be presented as **measurement, with its date
  and its instance**, because a reader who later measures four slots must not conclude the analysis
  was wrong.

Also verified and worth separating from the rate limit: HTTP **504** is returned for timeout/memory
exhaustion, which is a *different* failure with a different user-facing message ("that area is too
big") than 429. An adapter that collapses both into `{:error, :unavailable}` throws away the only
signal that tells the organizer their query, not the service, is the problem.

---

## 4. Proposed architecture

### 4.1 The four design questions, answered up front

**What is the smallest thing that makes the typed-name path better?**
A search that returns **URLs**, not structured place records. Decisively. Three reasons:

1. **It is the licence firewall.** The *intersection* of what Google, Yelp, Foursquare, Spoonacular,
   Edamam, ODbL and CDLA all permit you to keep is roughly `{opaque id, name, image URL, canonical
   link}`. A schema that can only hold `name`, `description`, `image_url`, `source_url` — which is
   exactly `Activity` today — cannot violate anyone's terms because it has nowhere to put the
   forbidden fields. Spoonacular's own carve-out ("you may indefinitely store the recipe id, the
   recipe title, and the recipe image url") is independent confirmation that this is the right
   retention boundary.
2. **A discovered option becomes byte-for-byte indistinguishable from a pasted one.** `02b`'s editor,
   the derived provenance line, the 140-grapheme description counter (invariant 11) and Refetch all
   work on day one with no new code and no new tests.
3. **One code path.** No second enrichment pipeline, no per-provider TTL registry in stage 1, no
   `metadata_fetched_at` semantics to reconcile.

The cost is real and should be stated: **you cannot render the frame as drawn.** See §4.6.

**What does the schema need?** In stage 1, **nothing**. Adding a result is
`Activities.add_activity(scope, group, %{name: name, source_url: website})` followed by the
`{:link_preview, activity.id, name}` async that already exists. Two nullable string columns —
`provider` and `provider_ref` — become worth adding only when you want in-pool de-duplication and the
frame's `Added ✓` state; index them `(group_id, provider, provider_ref)`. **Never add `rating`** — it
is the licence-poisoned field at every commercial provider. **Do not add `lat`/`lon`** until you
actually draw distance; under Google's terms a lat/lon column is a compliance liability with a
30-day clock, and you do not want that shape in the schema even for a provider that permits it.

**Where does location come from?** A **typed neighbourhood on the discover screen**, geocoded once by
Nominatim into a bounding box, cached indefinitely, and stored **on the group** as two nullable
fields (`search_area` string + a bbox). The key observation that makes this nearly free in privacy
terms: the group's location is *already* effectively public — the pool contains named restaurants and
everyone with the share link sees them. A neighbourhood string is a property of **the dinner, not the
person**, so it leaks nothing the pool doesn't already leak. Rejected alternatives: **browser
geolocation** (a permission prompt at the exact moment the organizer is racing a 5-minute clock, and
precise personal data that would force a rewrite of `/privacy`); **IP geolocation from Fly's headers**
(free and prompt-less, and rejected *because* it collects silently, besides being routinely 30 km
wrong). Nothing at all remains a legitimate configuration — an adapter declares `location: :unused`,
which is correct for movies and recipes, and it is not a special case.

**How does this degrade?** Every failure is a tagged tuple; `Discovery.search/3` never raises, per
`LinkPreview`'s contract. Discovery is **never load-bearing**: the frame already draws a dashed
`+ Add a place by name or link` row at the bottom of the results list, and that row is what makes the
whole feature optional. On an empty result it is promoted to the centre — *"No matches for 'ramen'
near Fishtown. Add it by name or link."* On a dead provider it becomes an inline notice **inside the
results area**, never a flash and never a crash, with the dashed row underneath and the chips still
interactive. Deleting the entire `Discover` LiveView must leave `02` working exactly as it does
today.

### 4.2 Modules

```
lib/consensus/discovery.ex                   # the context: search/3, available_types/0, safe wrapper
lib/consensus/discovery/result.ex            # the transient struct — never persisted as such
lib/consensus/discovery/provider.ex          # the behaviour
lib/consensus/discovery/provider/overpass.ex # stage 1 — one module, four activity types
lib/consensus/discovery/provider/overture.ex # stage 3 — same contract, local SQLite, no network
lib/consensus/discovery/provider/tmdb.ex     # stage 4
lib/consensus/discovery/cache.ex             # ETS; see 4.5
lib/consensus/discovery/geocoder.ex          # Nominatim, submit-only, cached indefinitely
lib/consensus_web/live/group_live/discover.ex # the screen behind the `Restaurant ›` chevron
```

**Sibling of `LinkPreview`, not a generalisation of it.** `LinkPreview.fetch/1` answers *"what is at
this URL"*; `Discovery.search/3` answers *"what matches this query"*. Different key spaces (a
normalised URL vs a `{type, query, bbox}` tuple), different TTL authority, different arity. A shared
`Consensus.External` over two callers is premature by definition. The `Fetcher` behaviour in
particular must **not** be reused — it is shaped for a redirect loop driven by the caller with a
per-hop SSRF re-check and a streaming body cap, because that is what an arbitrary user-pasted URL
needs; a provider call is a JSON GET against a fixed configured host.

### 4.3 Signatures

```elixir
defmodule Consensus.Discovery.Result do
  @enforce_keys [:name, :source]
  defstruct [
    :name,          # → Activity.name
    :website_url,   # → Activity.source_url, then LinkPreview fills the rest
    :source,        # :osm | :overture | :tmdb — for attribution, not for branching
    :external_ref,  # opaque, e.g. "node/1234567". Displayed never; persisted only from stage 3
    :chips          # [{label, value}] — DISPLAY ONLY, dies with the socket. See 4.6
  ]
end

defmodule Consensus.Discovery.Provider do
  @callback search(query :: String.t(), area :: Consensus.Discovery.Area.t() | nil, opts :: keyword()) ::
              {:ok, [Consensus.Discovery.Result.t()]} | {:error, atom()}

  @callback cache_policy() :: %{
              ttl_ms: pos_integer() | :none,
              error_ttl_ms: pos_integer(),
              may_store_results?: boolean()
            }

  @callback attribution() :: %{text: String.t(), url: String.t()} | nil

  # Added on review, 2026-08-09. §4.1 says "an adapter declares `location: :unused`, which is
  # correct for movies and recipes, and it is not a special case" — but the behaviour above had
  # no callback for it, so the only place that knowledge could have lived was a branch in the
  # LiveView on which provider was selected. That is invariant 12 re-entering one layer up,
  # which §4.4 warns about by name and then walks into. It has to be a callback.
  @callback location_mode() :: :required | :optional | :unused
end

defmodule Consensus.Discovery do
  @spec search(activity_type :: String.t(), query :: String.t(), area :: Area.t() | nil) ::
          {:ok, [Result.t()]} | {:error, atom()}

  @spec available_types() :: [String.t()]     # drives the chip row on `02`
  @spec attribution_for(String.t()) :: %{text: String.t(), url: String.t()} | nil
end
```

### 4.4 How this satisfies invariant 12

The rejected shape, stated so it is recognisable in review:

```elixir
# REJECTED — a branch on activity_type in the engine
case group.activity_type do
  "restaurant" -> Overpass.search(q, tags: [{"amenity", "restaurant"}])
  "movie" -> Tmdb.search(q)
end
```

The accepted shape — per-type behaviour is **data in config**, and the lookup is `Map.get/3`:

```elixir
config :consensus, Consensus.Discovery,
  providers: %{
    "restaurant" => {Discovery.Provider.Overpass, tags: [{"amenity", "restaurant"}]},
    "bar"        => {Discovery.Provider.Overpass, tags: [{"amenity", "bar"}]},
    "bowling"    => {Discovery.Provider.Overpass, tags: [{"leisure", "bowling_alley"}]},
    "cinema"     => {Discovery.Provider.Overpass, tags: [{"amenity", "cinema"}]},
    "movie"      => {Discovery.Provider.Tmdb, []}
  }

defp provider_for(type), do: Map.get(registry(), type, :none)
```

Four activity types resolve to **the same module with different data**. That is the strongest
available demonstration that the type is data and not a code path — you cannot write the branch even
if you want to, because there is nothing type-shaped to branch on.

Three consequences worth writing down:

- **A missing provider is a normal state, not an error.** `activity_type` is a free string validated
  only for presence, so a group created with `"karaoke"` must fall through to `{:ok, []}` and the
  typed/paste path, never raise.
- **The UI must not branch either.** `02`'s hardcoded `<.chip disabled>Bars</.chip>` /
  `<.chip disabled>Movies</.chip>` become derived from `Discovery.available_types()`, so a type with
  no registered provider renders disabled *by data*.
- **Normalisation belongs in the adapter.** If the LiveView maps provider-specific fields into the
  card, the branch reappears one layer up. Adapters return `%Result{}` or they are wrong.

**Reviewer's verdict on invariant 12, 2026-08-09: the design passes, with one hole now patched.**
Checked specifically for a hidden branch — a `case`, a `cond`, or a function head matching an
`activity_type` string — across §4.2, §4.3 and §4.4. There is none. The registry is a `Map` keyed by
type and read with `Map.get/3`, which the brief explicitly permits; `Result.source` is annotated
"for attribution, not for branching"; and the four-types-one-module arrangement is, as the draft
claims, genuinely strong evidence rather than a rhetorical flourish, because there is no per-type
code for a branch to live in.

The one hole was **outside** the three code blocks and is the classic way this invariant gets broken:
§4.1 said "an adapter declares `location: :unused`", but the `Provider` behaviour in §4.3 had no
callback for it. With no callback, the only place that knowledge could live is a conditional in the
`Discover` LiveView deciding whether to render the location field — which is the branch, relocated
one layer up, exactly as the third bullet below warns. A `location_mode/0` callback has been added to
§4.3 to close it. Worth noting *how* the hole appeared: not in the architecture, but in the gap
between two sections that were each individually correct. That is where this invariant will fail in
review too.

**Pin it the way this repo pins `fly.toml` stanzas and router pipelines.** `grep -rn activity_type
lib/` today returns exactly four lines: three in `activities/group.ex` (moduledoc, field, cast) and
one in `options.ex:841` (a `String.capitalize/1` for display). A source-text test asserting that
match list stays on a short allowlist makes invariant 12 *checkable* rather than aspirational, in the
same idiom as `test/consensus/deploy_config_test.exs`. **If only one thing from this document is
built, build that test.** It costs an hour and it is the guard that keeps the rest honest.

### 4.5 Caching

An ETS cache in the same shape as `LinkPreview.Cache`, with one deliberate difference: **TTL is
declared by the adapter via `cache_policy/0`, not read from one global config key.** For some
providers TTL is a compliance constant, not a tuning knob — Spoonacular's one-hour ceiling and
Brave's 8-hour POI ID expiry are not numbers anyone may tune. (Both re-verified 2026-08-09.
Spoonacular's is stricter than the draft implied and the omitted clause is the whole sentence:
"**With prior written permission from spoonacular**, you may cache user-requested data to improve
performance (for a maximum of 1 hour)" — so the one-hour ceiling is not a default you may rely on,
it is the *best case after asking*. The storable-forever carve-out is exact, though, and it is the
independent confirmation §4.1 leans on: "You can indefinitely store the recipe id, the recipe title,
and the recipe image url on your side.") The engine must honour `ttl_ms: :none`
by bypassing the cache entirely, and `may_store_results?: false` should make an adapter
**un-registerable at boot**, which turns "Foursquare is not allowed" from a memo into a fact the
supervision tree enforces.

- Overpass/OSM: 15 minutes is plenty. The durable artefact is the chosen `activities` row, not the
  result list.
- Nominatim: caching is **mandatory** under its policy and a neighbourhood's bbox is immutable —
  cache for days.
- Overture (stage 3): no cache at all. The query is a local SQLite read in ~0.4 ms.

`LinkPreview.Cache` is already fully generic (separate ok/error TTLs read fresh on every `put/2`,
lazy expiry, a 2,000-entry cap evicting by insertion time) — it is misnamed, not mis-shaped.
Parameterising `@table` from `start_link/1` opts and starting two children is the cheapest correct
move, and it touches a supervision-tree position that `test/consensus/application_test.exs` asserts,
so it must be deliberate. The honest alternative is ~120 duplicated lines. **Recommend
parameterising** — the separate ok/error TTL semantics is exactly where a re-derivation introduces a
bug — but the trade belongs in the D-050 entry either way.

**Not SQLite.** Invariants 15 and 17: SQLite permits one write transaction across the file,
production runs `default_transaction_mode: :immediate` so writers queue at `BEGIN`, and the ballot
write is the one moment the entire product funnels every user through simultaneously. Adding a
cache-miss write path to that file, to save a handful of Overpass calls after a redeploy, is a bad
trade. There is also no scheduler in this app by design (D-029), so expiry becomes a write-inside-a-
read or an unbounded table. Note the narrow exception: the **geocode** cache is genuinely
table-shaped (tens of immutable rows, and Nominatim *requires* caching) — but at this volume ETS is
still enough, so start there and move only if it demonstrably matters.

### 4.6 The UI, and the honest gap between it and the frame

`docs/design/screens/1a-3-phase-2-discover-behind-restaurant.html` is **its own screen** behind the
`Restaurant ›` chevron that is already drawn on `02` and already means "there is somewhere to go" —
it just isn't wired. The existing add-option field on `02` therefore **does not change at all**; the
only copy change is deleting `options.ex:880`, *"Restaurant search coming soon."* That is the
lowest-risk landing available: delete `Discover` and `02` still works.

**Async boundary (invariant 13).** `start_async`, and the keying rule is the *opposite* of
LinkPreview's, for a reason worth recording. LinkPreview keys by `activity_id` precisely so a second
paste cannot clobber an in-flight fetch for a different row. A search box has one in-flight query and
the newest one *should* supersede the older — so key it with a constant `:discovery_search`, stamp
the query into the result, and drop it on arrival if it no longer matches `@query`. **Do not search
on `phx-change`, even debounced** — every keystroke batch is an outbound request to a rate-limited
volunteer service, and for the location field it is a policy violation outright (trap F).
`phx-submit` only.

**Timeouts.** Measured Overpass latency was 1.5–6.1 s in one researcher's runs and 2.0–14 s in
another's, so `LinkPreview`'s 5 s receive timeout is too tight. Use ~10 s, render a skeleton of two
or three striped cards while `@searching`, and render a timeout as *"Search is slow right now — try
again"* with a retry, not as a failure.

**What cannot be rendered, and this is a decision the design owes an answer to.** The frame draws
`0.8 mi`, `$$$`, `4.5 ★`, `Italian` and `Open Thu`. Free data supplies at most two of those:

| Frame element | OSM / Overture | Verdict |
|---|---|---|
| Photo | **0%** — OSM has no image tags; Overture has no photos | Striped `photo_frame/1` placeholder until `LinkPreview` lands after add |
| `4.5 ★` rating | Absent from both | **Drop.** Every provider that has it forbids storing it |
| `$$$` price band | Sparse tag coverage | Drop for stage 1 |
| `Italian` cuisine | 80% of measured Philadelphia restaurants carry `cuisine` | **Keep** |
| `Open Thu` | 58% carry `opening_hours` | Optional; low value at 58% |
| `0.8 mi` distance | Computable from a bbox centroid | **Ambiguous** — see §6 |

**Rating and price band are precisely the fields that are paid AND unstorable at every commercial
provider.** If the frame must render as drawn, the entire cost analysis inverts and the cheapest path
becomes Brave Place Search at ~$0.50/month — whose terms then forbid keeping any of it past ~8 hours.
Recommend redrawing the card: photo (from `LinkPreview` after add) + name + cuisine chip + link.

---

## 5. Staged plan

> **Re-estimated on review, 2026-08-09.** The brief asked for a first stage that "could land in a
> day", and the draft answered by labelling the *largest* stage ~~*(one day)*~~. It is not one day;
> see the breakdown below. The honest fix is not to pad the estimate — it is to notice that this
> document already contains two genuinely one-day items and had them filed third and second. They
> are now **Stage 0**, they are independently valuable, and one of them *gates* the rest. Stages 1–4
> keep their numbers so §2's table references stay valid; only Stage 1's estimate and Stage 2's
> opening move.

### Stage 0 — the day-sized stage: pin the invariant, then measure whether the thesis holds *(one day, and do it first)*

Two items, neither of which needs a design decision, a vendor, a key, or a migration.

**0a. The invariant-12 source-grep test *(~1 hour)*.** §4.4 already argues this is the single
highest-leverage artefact in the document — "if only one thing from this document is built, build
that test" — and then filed it inside the biggest stage, where it cannot land until everything else
does. It has no dependency on discovery existing. Verified on review: `grep -rn activity_type lib/`
returns **exactly four lines today** — `activities/group.ex` lines 6 (moduledoc), 33 (field), 64
(cast), and `group_live/options.ex:841` (`String.capitalize/1`, display only). That is a four-line
allowlist a test can assert against *now*, in the idiom of `test/consensus/deploy_config_test.exs`,
turning invariant 12 from prose into something CI enforces — including against the discovery work
that follows.

**0b. Measure the production 403 rate *(~2 hours, and it gates everything)*.** This was Stage 2's
opening instruction and it is in the wrong place, because **it can invalidate the recommendation**.
The entire thesis is "search returns URLs, `LinkPreview` enriches them". If Fly's egress IP is 403'd
by venue and recipe sites, the enrichment never happens, discovery degrades to a list of bare names,
and §7's null option wins. One `fly ssh console` and a handful of `Req` calls settles it. §7 already
says "**measure that before building stage 1**" — Stage 0 is simply that sentence given a slot in the
plan. It also measures how much of the **already-shipped** paste feature is failing silently in
production, which is worth the two hours on its own.

Ship 0a regardless. Let 0b decide whether Stage 1 happens at all.

### Stage 1 — the seam, with a live Overpass adapter ~~*(one day)*~~ *(3–4 days — corrected 2026-08-09)*

Build `Discovery`, `Result`, the `Provider` behaviour, the config registry, the `Overpass` adapter,
the `Discover` LiveView, and — moved to Stage 0a — the source-grep test pinning invariant 12.
Register `restaurant`, `bar`, `bowling` and `cinema` — all four pointing at the same module with
different tags, because that is the proof that the design works. No location yet: use a fixed bbox
from a hardcoded default or a typed free-text term, and take the shortcut visibly. **Zero migrations.
Zero new columns.** `$0.00`.

Ship it behind the dashed escape hatch, so the failure mode is "no results, add it yourself".

**Why not a day.** The scope is a context, a behaviour, an adapter, *and a new screen*, in a repo
with a 606-test suite and a documented design system. Costed against this repo's actual conventions
rather than against a greenfield:

| Piece | Realistic | Why it is not smaller *here* |
|---|---|---|
| `Discovery` + `Result` + `Provider` + registry | ~0.5 day | The genuinely easy part; the draft's estimate is right about this and only this |
| `Overpass` adapter | ~1 day | Overpass QL generation, JSON decode, tag→`Result` mapping, website extraction, and a **four-way error taxonomy** (429 vs 504 vs timeout vs malformed — see trap L). Plus a `Fetcher`-style behaviour and a `$callers`-walking test stub, because that is how this repo injects HTTP doubles (`test/support/link_preview_stub.ex`) — it is not optional here |
| `Discover` LiveView | ~1–1.5 days | A **new screen**: route, `live_session`, scope auth, `start_async` with the constant-key/stale-drop rule from §4.6, skeleton + empty + provider-down + attribution states, `Sticker` primitives, the add-to-pool wiring into `Activities.add_activity/3`, the follow-on `LinkPreview` async, and `Phoenix.LiveViewTest` coverage for each state |
| Promote `check_host/1` + pin it | ~1 hour | Small, but it is a change **inside the SSRF guard** (trap J), so it carries review weight out of proportion to its size — and it contradicts this stage's "we don't touch `link_preview.ex`" framing |
| D-050, `CLAUDE.md` invariant 12 update, doc greps | ~0.5 day | The repo's working agreement is explicit: *"when a change invalidates a fact, grep for that fact across every doc before you finish"*. A new context and a new route invalidate several |

None of these is padding, and none is removable by working faster; they are the cost of landing a
screen in *this* repo. Anyone quoting "one day" for Stage 1 should quote 3–4 and point here.

**Why Overpass first when I already know it will be flaky.** Two researchers measured the public
endpoint independently: one saw 1.5–6.1 s responses, the other saw **2 of 8 sequential queries fail**
(`rate_limited` and a dispatcher timeout) against a stated per-IP allowance of roughly 2 slots — and
on one Fly machine that allowance is shared by *every organizer at once*, not per user. That is a
poor production backend. It is nonetheless the right day-one adapter, because **the seam is the risky
part and the source is the swappable part**: an HTTP call is a pattern this repo has already proven
three times over, it needs no build artefact and no geographic-scope decision, and it forces the
degradation path to be built and exercised for real rather than assumed. Budget for the move to
stage 3; do not build anything that assumes a network call exists.

### Stage 2 — teach `LinkPreview` to read `schema.org` JSON-LD *(half a day, independent)*

Orthogonal to everything above and possibly the highest value-per-hour item in this document. The
Oct-2024 Web Data Commons crawl found 2,922,378 `schema.org/Recipe` entities across 37,304 domains,
3,785,443 `Movie` and 10,288,815 `Book`; Google requires only `name` + `image` for a Recipe rich
result, so the SEO incentive to keep emitting it is permanent. **This is the answer to "recipes as a
dinner option": there is no recipe provider to buy, because the paste field already works and this
change makes it work better.** It adds no vendor, no key, no licence and no column, and it serves
recipes, movies, books and events at once. Ship it whenever.

**The 403 measurement that used to open this stage is now Stage 0b**, because it gates Stage 1 too,
not just this one. Restating what it is checking: one researcher measured, from a residential IP with
a browser UA, `allrecipes.com` 403, `seriouseats.com` 403, `foodnetwork.com` 403, `yelp.com/biz` 403,
`imdb.com` 202 with no OG tags. Fly egress is datacenter IP space with a worse reputation, and
`Fetcher.Req` sends whatever UA Req defaults to.

**A caveat the draft did not draw out, and it cuts in this stage's favour.** Those 403s are *recipe
aggregators and Yelp* — the sites with the strongest commercial incentive to block bots. They are not
representative of the long tail this feature actually depends on: an individual restaurant's own site,
a neighbourhood bar's Squarespace page, a cinema's listings page. A 403 rate measured on
`allrecipes.com` predicts the **recipe** half of this stage and says comparatively little about the
**venue** half, which is what Stage 1 feeds on. Measure both populations separately, or Stage 0b will
produce one pessimistic number that kills a feature it did not actually test.

### Stage 3 — replace the Overpass adapter with a local Overture Places extract *(the destination)*

`overturemaps download --type=place --bbox=…` pulled all 87,347 places in a Philadelphia bbox in 8.4
seconds; trimmed to name/category/lat/lon/website/address and indexed with FTS5 that is a **17.6 MB
SQLite file**, and a "pizza in Fishtown" query (FTS match + category filter + bbox) answered in
**0.37 ms with zero network calls**. It beats OSM roughly 2:1 on the verticals that matter (1,671
`restaurant` + 1,024 `pizza_restaurant`, 529 `bar`, 48 `cinema`, 26 `bowling_alley` vs Overpass's
1,317 / 223 / 21 / 13 for the same bbox), and — the number that decides the whole design — **88% of
Overture places carry a `websites` field against OSM's 48%**, which is what feeds `LinkPreview`.

It removes, in one move: the rate limit, the shared-IP problem, the network call, the volunteer-
infrastructure dependency, the timeout skeleton, *and* the ODbL derived-database question (trap I).
The extraction tooling is Python/DuckDB, so it is a **build-time** step on a laptop — nothing new runs
in production, no second service, no second machine. Cost: ~18 MB of the existing Fly volume
(≈ $0.003/month at $0.15/GB-month) and a manual quarterly re-extract. **The adapter contract makes
this a config change.**

Two decisions this stage forces and neither is hard: **geographic scope** (one metro in the image? N
metros on the volume? re-extract on demand?) and **staleness** (monthly releases mean a closed
restaurant lingers for weeks — `operating_status` and `confidence` fields exist and should be
filtered on).

### Stage 4 — location, then a second real vertical

Location: `Discovery.Geocoder` over Nominatim, `phx-submit` only, cached indefinitely, two nullable
columns on `activity_groups`, and one honest sentence added to `/privacy` under "If you organize".
(Runner-up: **Photon**, whose terms explicitly support typeahead where Nominatim's forbid it —
`"You can use the API for your project, but please be fair - extensive usage will be throttled"`, no
published number, no SLA. Take it if and only if typeahead is judged worth an unmetered dependency.)

Then TMDB for movies — but resolve trap K first, because the answer is an email, not a judgement
call.

### Deferred, deliberately

`provider`/`provider_ref` columns and in-pool de-duplication; the `Added ✓` state; distance; a
general-search adapter (Firecrawl or Brave) used **only** as an enrichment fallback for the ~12–30%
of places with no `website` tag — a bounded, optional adapter worth building only once real usage
shows the missing-website case matters. Ranked-choice, travel, lodging: Post-MVP, per PRD scope
discipline.

### Record the decision

This warrants a **D-050** in `docs/decisions.md` (the log is currently at D-049): discovery is
URL-returning not record-returning; the registry is data; commercial place APIs are rejected
**by terms, not by price**, so nobody re-litigates Google and Yelp in six months.

---

## 6. What could not be determined

1. **Google Service Specific Terms §14.3** — the reported 30-day lat/lng caching allowance.
   `cloud.google.com/maps-platform/terms/maps-service-terms` truncated on fetch and I could not reach
   §14. *(Narrowed 2026-08-09: the **"no non-Google map"** half of this item is no longer unknown —
   the equivalent rule is stated plainly on the policies page and is quoted in trap A.)* The verified
   place-ID-only finding plus the Google-logo obligation are together sufficient to reject Google, so
   this does not change the verdict. Also unread: the separate **EEA** terms, which govern customers
   with an EEA billing address.
2. **Does persisting an `activities` row that originated from a Brave result "create a database of
   Search Results"?** My reading — it does if the fields come from Brave, and does not if only the URL
   is kept and `LinkPreview` re-derives the rest from the venue's own HTML — is a legal judgement, not
   Brave's documented position. Needs an email before any Brave-backed feature ships.
3. **What Yelp's $229/month Base fee actually includes** before the "$5.91 per additional 1,000"
   overage starts. The pricing page states both numbers and never the inclusion. Does not change the
   verdict; would change a comparison-table cell.
4. **TripAdvisor's per-1,000 overage price** is not published anywhere public — the FAQ says the chart
   appears at checkout, which requires a card. Would need a throwaway signup.
5. **Serper's real pricing.** `serper.dev/pricing` returns 404; the $50 minimum prepay, the ~$0.30–$1.00
   per 1,000 rates and the 6-month credit expiry all come from third-party 2026 blogs. **Do not budget
   against them.**
6. **Firecrawl's monthly-billed prices and whether its free plan permits commercial use.** The pricing
   page shows only yearly-billed figures ($16/$83/$333/$599); monthly rates are inferred. The ToS is
   silent on both commercial use of the free tier and on retaining scraped content — and *silence is
   not a grant*.
7. **Whether production's `Fetcher.Req` gets the same results a laptop does.** The 403 measurements
   were taken from a residential-ish IP with a browser UA. This is cheap to settle and it gates
   stage 2 — and it may reveal that part of the *shipped* paste feature is already failing silently.
8. **How well OSM's `website` coverage holds outside dense US cities.** The 48–70% figures are two
   bboxes in central Philadelphia, a city with an unusually engaged OSM community. This is the single
   number that most determines whether "search returns URLs, `LinkPreview` enriches" feels good or
   feels empty. Measure two or three more bboxes — including a suburb — before committing.
9. **The on-disk size of a US-wide Overture extract**, and whether it fits the volume's 1 GB
   `initial_size` (auto-extend reaches 10 GB). Naive extrapolation from ~53–61 M global places
   suggests low single-digit GB for the US. One CLI run settles it.
10. **Overture licence durability.** CDLA-Permissive-2.0 is asserted per-release and per-source; only
    release 2026-07-22.0 was checked. Whether Overture has ever relicensed a source retroactively is
    unknown, and it matters if a shipped artefact depends on it.
11. **Does `0.8 mi` mean distance from the *user* or from the neighbourhood centroid?** The frame's
    location chip says "Silver Lake", which is centroid-shaped; the distance label is point-shaped.
    Only the first is achievable without a geolocation permission prompt. A product decision.
12. **Is Consensus commercial, or does it intend to be?** This is upstream of TMDB's licence and of
    how strictly Yelp's and Google's terms read. PRD invariant 5 (a booking/ticketing CTA) is exactly
    the feature that would settle it the wrong way. Decide before stage 4, not after.
13. **Result quality with mitigations applied.** The unmitigated web-search measurements are bad
    (7 of 10 aggregators for a restaurant query; **zero** operating venues in the first nine for
    "bowling alley Ballard Seattle"). Untested: Firecrawl `/search` with `excludeDomains`, and Brave
    with an inline Goggle `$discard,$site=yelp.com`. Costs about $0.15 of Brave credit and would
    settle whether a general-search *enrichment fallback* is worth building at all.
14. **Foursquare's actual free allowance** *(added on review, 2026-08-09)*. Their pricing page states
    two incompatible numbers in the same view: a tier table reading `0 – 500 Calls · $0.00 CPM` /
    `501 to 100,000 Calls · $15.00 CPM`, and a headline reading "Enjoy up to **10,000 free calls** on
    Pro endpoints." At 1,000 calls/month that is the difference between **$7.50 and $0.00**. No
    effective date appears anywhere on the page, so the draft's "from 2026-06-01" is also unsupported
    and has been removed from §8. This does not change the verdict — Foursquare is rejected on trap C,
    which is unambiguous and verified — but it is a warning about the *class* of claim: a vendor page
    that contradicts itself will be quoted selectively by whoever wants a given answer.
15. **Brave Place Search's price is not on Brave's pricing page** *(added on review, 2026-08-09)*. The
    pricing page lists Search, Answers, and Spellcheck/Autosuggest only; the Place Search docs say
    only "billed separately from Web Search. Check your subscription dashboard for current limits and
    usage." The `$5 per 1,000 requests` figure comes from a Brave **blog post** dated 2026-07-08 —
    first-party, but marketing, and a blog post is not a price list. Verify in the dashboard before
    budgeting.
16. **Whether Yelp §5(a) has a business-id carve-out** *(added on review, 2026-08-09)*. The draft
    asserted "(business IDs excepted)". §5(a) as fetched contains no such exception. Either it lives
    in a proviso the fetch did not surface, or Yelp — unlike Google and Foursquare, both of which
    grant a permanent-id carve-out explicitly — does not grant one. Only matters if anyone revisits
    Yelp, which trap D says nobody should.
17. **Every measured number in stage 3 is single-sourced and unreproduced** *(added on review,
    2026-08-09)*. The 87,347 places / 8.4 s download / 17.6 MB file / 0.37 ms query / 88%-vs-48%
    website coverage figures are one researcher's run against one Philadelphia bbox. They are
    plausible and internally consistent, and **the recommendation leans on the 88% figure harder than
    on anything else in the document** — it is what makes "search returns URLs, `LinkPreview`
    enriches" work at all. It was not re-run during this review and cannot be verified from a
    licence or pricing page. Re-run it, on a second metro, before Stage 3 is committed to. This is
    the same concern as item 8, escalated: item 8 doubts OSM's 48%; this doubts the *comparison*.

---

## 7. The null option, stated fairly

Doing nothing is defensible and deserves its paragraph. `02` already accepts a typed name and a
pasted URL, and the pasted URL already produces a photo, a title and a description. For five friends
choosing dinner, *"paste the restaurant's Instagram or website"* is a **complete** workflow — arguably
better than search, because the organizer usually already knows where they want to go. The screen's
copy is honest about the gap. What discovery genuinely adds is help for the organizer with *no*
candidate in mind, and how large that population is remains unknown.

**What would change my mind toward doing nothing:** if the stage-2 measurement shows Fly egress is
403'd by most venue and recipe sites, then `LinkPreview` enrichment is unreliable in production, the
"search returns URLs" thesis loses its payoff, and discovery degrades to a list of bare names — which
is what `02` already offers. **Measure that before building stage 1.**

The cost of waiting is small but real: the `Restaurant ›` chevron and the dashed `Bars`/`Movies`
chips keep promising something that isn't there.

---

## 8. Sources

All read **2026-08-09**. Entries marked ✔ were verified directly at the primary source while writing
this document; unmarked entries are researcher-reported and are flagged as such in the text where
they carry weight. Entries marked **✔✔** were additionally **re-fetched independently during the
2026-08-09 review pass**; where a re-fetch contradicted the draft, the correction is inline in the
relevant section and the source line says so.

**Commercial place APIs**
- ✔✔ https://developers.google.com/maps/documentation/places/web-service/policies — place IDs storable indefinitely, and the **only** named exemption; also "Places API results displayed on a map must be shown on a Google Map" and the Google-logo requirement when displaying without a map *(the map clause was surfaced by the review re-fetch — see trap A)*
- https://cloud.google.com/maps-platform/terms — ToS §3.2.3(a) No Scraping, §3.2.3(b) No Caching
- https://cloud.google.com/maps-platform/terms/maps-service-terms — §14; **could not read, truncated** (still unread after the review pass)
- https://developers.google.com/maps/billing-and-pricing/pricing — per-SKU free allowances and prices
- ✔✔ https://business.yelp.com/data/resources/pricing/ — Base $229/mo + $5.91/1,000; Enhanced $299/mo + $6.57/1,000; Premium $643/mo + $14.13/1,000; 5,000 trial calls only. **Exact to the dollar on re-fetch**
- ✔✔ https://terms.yelp.com/developers/api_terms — §5(a) "cache, record, pre-fetch, or otherwise store any portion of the Yelp Content for a period longer than twenty-four (24) hours from receipt"; §5(b) "use it to update or create your own database of business listing information". *(Upgraded from researcher-reported. Note `www.yelp.com/developers/api_terms` 302s here; the old URL is kept in trap D for traceability.)*
- ✔✔ https://docs.foursquare.com/fsq-developers-places/reference/usage-guidelines — "Pay as You Go & Sandbox Customers: no caching permitted"; also the unlimited-caching carve-out for `fsq_place_id`, photo IDs and `fsq_addr_id`, and the visual-or-contextual credit requirement
- ✔✔ https://foursquare.com/pricing/ — ~~500 free Pro calls/month from 2026-06-01, then $15.00 CPM~~ **the page contradicts itself**: tier table `0 – 500 Calls · $0.00 CPM` / `501 to 100,000 · $15.00 CPM`, headline "up to 10,000 free calls on Pro endpoints". **No effective date appears on the page — the "from 2026-06-01" claim is withdrawn** *(corrected 2026-08-09; see §6 item 14)*
- ✔✔ https://docs.mapbox.com/api/search/search-box/ — "All data returned by the Search Box API endpoints is only available for temporary use"; default rate limit "10 requests per second"
- https://www.mapbox.com/pricing — Search Box free bands; Permanent Geocoding $5.00/1,000
- https://tripadvisor-content-api.readme.io/reference/caching-policy — location_id only

**Open data**
- ✔✔ https://dev.overpass-api.de/overpass-doc/en/preface/commons.html — "a maximum of about 10000 requests per day", "below about 1 GB per day", HTTP **429** on rate limit and HTTP **504** on timeout/memory. **No per-IP slot count is published** — the number is read at runtime from the status endpoint *(see trap L)*
- ✔✔ https://operations.osmfoundation.org/policies/nominatim/ — all four clauses re-verified verbatim: 1 req/s, identifying UA required, "Results must be cached on your side", autocomplete "must not" be implemented. Also "bulk geocoding of larger amounts of data is not encouraged"
- ✔ https://www.openstreetmap.org/copyright — ODbL, credit + licence link
- https://osmfoundation.org/wiki/Licence/Community_Guidelines/Substantial_-_Guideline — the "<100 Features / non-systematic" line
- https://osmfoundation.org/wiki/Licence/Attribution_Guidelines
- ✔✔ https://docs.overturemaps.org/attribution/ — places has **no theme-level licence**, only per-source: Meta/Microsoft/PinMeTo/Krick/RenderSEO/DAC/BrightQuery = CDLA-Permissive-2.0, Foursquare = Apache-2.0, AllThePlaces = CC0-1.0. base, buildings, **divisions**, transportation = ODbL. **addresses = permissive but per-jurisdiction** (CC BY 4.0 / CC0 / OGL variants) — *a sixth theme the draft omitted; see trap G*
- https://cdla.dev/permissive-2-0/ — sole obligation is making the licence text available
- https://opensource.foursquare.com/os-places/ — 100M+ POIs, 1,000+ categories, Apache 2.0
- ✔ https://photon.komoot.io/ — "please be fair - extensive usage will be throttled"; typeahead supported; no availability guarantee
- https://taginfo.openstreetmap.org/ and https://taginfo.geofabrik.de/north-america:us/ — tag counts

**Search APIs**
- ✔✔ https://api-dashboard.search.brave.com/documentation/resources/terms-of-service — §(storage) "store, cache, or create a database of Search Results … other than transient storage" **[verified verbatim, unchanged]**; §4(d) "Customer **may** provide attribution" — **permissive, and no clause anywhere conditions the credit or any tier on it** *(this contradicts the draft; see trap B)*
- ✔✔ https://api-dashboard.search.brave.com/documentation/pricing — Search $5.00/1,000, 50 req/s, "$5 in credits every month"; Answers $4.00/1,000 at 2 req/s. **Place Search is not listed on this page**
- ✔ https://api-dashboard.search.brave.com/documentation/services/place-search — "POI IDs are ephemeral and expire after approximately 8 hours. Do not store them for later use." Pricing deferred to the dashboard *(added on review)*
- https://brave.com/blog/place-search-improved/ — "$5 per 1,000 requests" for Place Search, post dated 2026-07-08. **First-party blog, not a price list** *(added on review; see §6 item 15)*
- ✔✔ https://www.firecrawl.dev/pricing — free 1,000 credits/month recurring, no card required; Hobby $16/mo, Standard $83/mo, Growth $333/mo, Scale $599/mo, **all billed yearly; monthly rates still not displayed**
- ✔✔ https://docs.firecrawl.dev/features/search — "2 credits per 10 results, rounded up"; +1 credit/page with `scrapeOptions`, +4 for enhanced proxy or JSON mode
- https://raw.githubusercontent.com/firecrawl/firecrawl/main/apps/api/src/search/index.ts — self-hosted `/search` falls back to a DuckDuckGo scrape
- https://raw.githubusercontent.com/firecrawl/firecrawl/main/SELF_HOST.md — Redis + RabbitMQ + Postgres + Playwright
- https://serpapi.com/legal — §13 legal shield excluded from Free/Starter/Developer
- https://serper.dev/ — 2,500 free queries; **pricing page 404s**
- https://github.com/searxng/searxng/issues/2515 — "Google is actively blocking SearXNG instances"
- https://docs.searxng.org/dev/search_api.html — many public instances disable JSON

**Verticals**
- ✔✔ https://www.themoviedb.org/api-terms-of-use — 6-month cache cap and the exact required notice both re-verified verbatim. **The phrase "does not permit any commercial use" is NOT on this page**; the operative clause is "Selling, leasing, or sublicensing … or deriving revenues from the use or provision of TMDB, the TMDB APIs, or TMDB Content … is only permitted under a separate written agreement" *(corrected 2026-08-09; see trap K)*
- https://developer.themoviedb.org/docs/rate-limiting — "somewhere in the 40 requests per second range"
- https://webdatacommons.org/structureddata/2024-12/stats/schema_org_subsets.html — Recipe / Movie / Book entity counts
- https://developers.google.com/search/docs/appearance/structured-data/recipe — `name` + `image` required
- ✔✔ https://spoonacular.com/food-api/terms — "**With prior written permission from spoonacular**, you may cache user-requested data … (for a maximum of 1 hour)" — the permission precondition was omitted from the draft; "You can indefinitely store the recipe id, the recipe title, and the recipe image url on your side"
- https://developer.edamam.com/edamam-recipe-api — stored data must sit "behind a password"
- https://www.themealdb.com/api.php — the dataset totals ~789 meals (enumerated a–z)

**Infrastructure**
- ✔✔ https://fly.io/docs/about/pricing/ — shared-cpu-1x $2.02/$3.32/$5.92/$11.11 at 256 MB/512 MB/1 GB/2 GB (**Amsterdam region — the page has a region selector and rates differ by region**); volumes "$0.15/GB per month of provisioned capacity"; snapshots $0.08/GB-month with first 10 GB free

**In-repo**
- `CLAUDE.md` invariants 11, 12, 13, 14, 15, 17 and the External API calls working agreement
- `docs/decisions.md` D-029, D-030, D-032, D-033, D-034, D-041
- ✔✔ `lib/consensus/link_preview.ex` — `@receive_timeout_ms 5_000` (line 37), confirming §4.6's "too tight for Overpass"; **`check_host/1` is `defp` at line 212**, not public *(this contradicts trap J as originally written — see the correction there)*
- ✔✔ `lib/consensus/link_preview/cache.ex` — `@max_entries 2000` (line 33), separate `cache_ttl_ms`/`cache_error_ttl_ms` read fresh on every `put/2` (lines 96–97), lazy expiry, oldest-first eviction. §4.5's description is accurate. **`@table __MODULE__` (line 32) is referenced in `get/1`, `put/2`, `flush/0`, `size/0` and `init/1`**, so "parameterise `@table` from `start_link/1` opts" means threading a table name through five functions plus their specs — still the right call, but not a one-line change
- ✔✔ `lib/consensus_web/live/group_live/options.ex` — line 841 `{String.capitalize(@group.activity_type)}`, the only `activity_type` read in `lib/`; line 880 the "Restaurant search coming soon" copy; lines 843–844 the `<.chip disabled>Bars</.chip>` / `<.chip disabled>Movies</.chip>` pair §4.4 proposes to derive from `available_types/0`. **`grep -rn activity_type lib/` returns exactly the four lines §4.4 claims** — re-run during the review pass
- ✔✔ `docs/decisions.md` — last entry is **D-049**, so §5's "D-050" is the correct next number *(re-verified)*
- ✔✔ `docs/design/screens/1a-3-phase-2-discover-behind-restaurant.html` — the frame does contain `0.8 mi`, `$$$`, `4.5`, `Italian`, `Open Thu`, `Silver Lake`, a `Menu` link and the dashed `Add a place by name or link` row, exactly as §4.6 describes
