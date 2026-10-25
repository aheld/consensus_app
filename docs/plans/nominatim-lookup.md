# Plan — move the Assisted Add's lookup from Overpass to Nominatim

Status: **Implemented 2026-10-25 as D-059**, amending D-052 §3 and D-056 §4–5 in place.
Where D-059 and this plan disagree (the `:busy` tag, the two-line provider log, the ship
bar), D-059 describes the code.

**What this changes.** `Consensus.Discovery`'s live provider. Typing "Vernick" on `02 add
options` and pressing **Add** still fires one background search that either offers *"Is
this it?"* or stays silent. What answers that search changes from the public Overpass API
to Nominatim's POI search. That is the same OpenStreetMap data, the same licence and the
same attribution line, and it is the service that already resolves the group's search
area. The UI, the `Provider` behaviour, `Result`, the cache, the registry shape and the
failure-is-silence rule are all unchanged.

**Why.** PRD § "Creating a session" asks that adding a known option be quick and produce
a recognisable card. In practice the assist almost never produces a suggestion. The
2026-10-25 review found four causes, and the first one decides it:

1. **Overpass is not answering.** From a residential connection, 35 attempts at the
   app's exact query (Philadelphia bbox, `amenity=restaurant`, nine real venue names, five
   tries each with backoff) over ~10 minutes produced **zero** responses. Each attempt
   either returned 502 within 0.4s or ran past 15s. The app's budget is 10s. The 502 body
   reads: *"This Overpass API server is currently at capacity. All query workers are busy
   and the request queue is full … This public endpoint is intended for browser-based and
   human-operated tools. For automated or high-volume use, run a local Overpass API
   instance."* Two mirrors (`overpass.private.coffee`, `overpass.kumi.systems`) also
   timed out. That may have been the test machine's network, but it does not matter: no
   instance is one we could depend on. D-052 makes every failure render as silence, so
   an organizer cannot tell "the server is down" from "no match". A feature that is
   down nearly all the time looks exactly like one that matches badly.
2. **Matching is a literal substring.** The QL is `["name"~"<escaped query>",i]`.
   "Beddia Pizzeria" misses "Pizzeria Beddia", "Joes" misses "Joe's", "Cafe" misses
   "Café", and "and" misses "&".
3. **The category filter is too narrow.** `restaurant` → `amenity=restaurant` only. In
   Philadelphia's OSM data Shake Shack is `fast_food`, Cafe La Maude is `cafe`, and
   Federal Donuts is split across `restaurant` and `fast_food`. `bar` misses `pub`.
4. **The area geocode has no country bias.** `"19125"` (a Philadelphia ZIP) resolves to
   La Spezia, Italy. That bbox is stored on the group and every later lookup for the
   group searches Liguria.

The same nine names, same bbox, against Nominatim (`layer=poi`, `bounded=1`) on the same
day, at about 1s each:

| Typed | Nominatim | Photon |
|---|---|---|
| Zahav | ✅ Zahav `restaurant` | ✅ |
| Vernick | ✅ Vernick Food & Drink `restaurant` | ✅ |
| Beddia Pizzeria | ✅ Pizzeria Beddia `restaurant` | ✅ |
| Federal Donuts | ✅ `restaurant` + `fast_food` | ✅ |
| Shake Shack | ✅ `fast_food` | ✅ |
| Cafe La Maude | ✅ `cafe` | ✅ |
| Joes Pizza | ❌ | ✅ Joe's Pizza |
| Dizengof (typo) | ❌ | ❌ |
| dinner at Zahav | ❌ | ❌ |

One Nominatim response carries everything `Result` needs: `name`, `category`/`type`,
`address.house_number` + `address.road`, `extratags.website`, `extratags.cuisine`.

Read first: [D-052](../decisions.md) (all of it, especially §3 and §9), **D-056**
(telemetry; its §4–5 name Overpass), **D-030** (SSRF guard), **D-033** (`max_cases: 1`);
[docs/research/activity-discovery.md](../research/activity-discovery.md) trap F
(Nominatim's policy) and §4.3–4.5; CLAUDE.md engineering invariants 2 (supervision
order is asserted), 12 (activity type is data), 13 (network calls only from
`start_async`).

---

## 1. Decisions this plan makes

### 1.1 Nominatim replaces Overpass as the only registered provider

All four registry types point at a new `Consensus.Discovery.Provider.Nominatim`. The
Overpass adapter, its HTTP seam, its stub and its tests are **deleted, not kept
unregistered**. Dead code that looks live invites someone to re-register it. Git keeps it
if Overpass ever becomes viable again (on a self-hosted instance, which is research Stage
3's job anyway).

**Overture stays the destination** (D-052 §3). This is a better Stage 1, not a new
roadmap.

### 1.2 This does not contradict research trap F, and the plan says why

Trap F ends: *"Nominatim also explicitly declines to answer 'all objects of a type in an
area' and points you at Overpass; do not try to make one tool do both jobs."* That
warning is about **enumeration**, meaning browsing every restaurant in Fishtown. That is
the parked Discover screen, and it stays parked. The assist is **lookup of a named
place**, which is exactly what Nominatim is built for. The other three trap-F clauses
bind harder now and are designed for:

| Policy clause | How it is met |
|---|---|
| Max 1 request/second | One app-wide gate shared by the search and the geocoder (§1.4). |
| Results must be cached | Successes cached 24h, errors 1 min, keyed by type + lowercased query + area (§1.6). |
| No autocomplete | Unchanged: the add form has no `phx-change`, one search per **Add**, pinned by `options_assist_test.exs` (D-052 §9). |
| Identifying User-Agent | The existing `@user_agent`, moved to one shared module (§1.3). |

### 1.3 One Nominatim client, two callers

New `Consensus.Discovery.Nominatim` owns the endpoint, the User-Agent, the timeouts,
the HTTP seam (`Consensus.Discovery.Nominatim.HTTP`, behaviour + `.Req`) and the rate
gate. It exposes:

- `search(params :: keyword()) :: {:ok, [map()]} | {:error, atom()}`, which never raises
  and returns decoded JSON;
- `request_url(params) :: String.t()`, the exact GET that goes on the wire, for D-056's
  `repro` lines.

`Consensus.Discovery.Geocoder` becomes a thin caller (its `request_url/1` delegates), and
so does the new provider. Today the geocoder carries its own copy of the endpoint and UA.
Two copies would mean two gates that can't see each other, and the 1 req/s limit is per
application, not per module.

`geocoder_http_stub.ex` becomes `nominatim_http_stub.ex` (same `$callers` idiom).
`overpass_http_stub.ex` is deleted.

### 1.4 The rate gate: one slot per second, bounded wait, refusal is silence

`Consensus.Discovery.Nominatim.Gate` is a supervised GenServer holding the monotonic time
of the next free slot. `reserve(max_wait_ms)` either returns `{:ok, wait_ms}` and moves
the slot forward 1 000 ms, or returns `{:error, :busy}` if the wait would exceed
`max_wait_ms`. The **caller** sleeps the wait. Callers are already inside
`start_async`, so sleeping a Task is fine and the GenServer never blocks.

- `max_wait_ms` is **3 000**. An organizer who adds five names in four seconds gets the
  first four looked up and the fifth stays silent. That beats queueing a ten-second tail
  behind the shimmer.
- `:busy` maps to `{:error, :rate_limited}`. That is the same tag a 429 produces, and the
  same silence.
- Cache hits never touch the gate.
- Supervision: directly after `Consensus.Discovery.Cache`, before the endpoint.
  `test/consensus/application_test.exs` asserts that position (invariant 2's idiom).
- Test config sets the slot interval to 0 so the suite never sleeps. The gate's own test
  sets it explicitly.

This is not a scheduler (D-029 still holds): it holds one integer and does no work of its
own.

### 1.5 The query

```
GET https://nominatim.openstreetmap.org/search
  ?q=<typed name, trimmed>
  &format=jsonv2
  &layer=poi
  &viewbox=<min_lon>,<max_lat>,<max_lon>,<min_lat>   # left,top,right,bottom
  &bounded=1
  &limit=10
  &addressdetails=1
  &extratags=1
```

- **`limit=10`, filtered down to the type's categories, then capped at 3** by
  `Consensus.Discovery` as today. Asking for more than we show is what lets a
  `cafe` named "Vernick Coffee Bar" sit next to the restaurant without crowding out a
  match.
- **`viewbox` order differs from `Area.bbox`'s** (`{min_lat, min_lon, max_lat, max_lon}`).
  The reordering lives in exactly one function and is pinned by a test, like the
  geocoder's `build_area/2` reordering.
- **A minimum search span.** A neighbourhood that geocodes to a point comes back as a
  ±0.01° box (Fishtown: ~2 km). A favourite place three blocks past the neighbourhood
  line is then out of bounds. The adapter widens any bbox narrower than **0.04°** on
  either axis to 0.04° around its centre, at search time only. The stored
  `search_bbox` is unchanged.

### 1.6 Categories are registry data, filtered after the response

The registry keeps its shape (invariant 12 is unchanged and still machine-checked). The
option is renamed from `tags:` to **`categories:`**, because it is now an allowlist on
results rather than a query filter, and a name that describes the old meaning would
mislead:

```elixir
config :consensus, Consensus.Discovery,
  providers: %{
    "restaurant" =>
      {Consensus.Discovery.Provider.Nominatim,
       categories: [
         {"amenity", "restaurant"}, {"amenity", "fast_food"}, {"amenity", "cafe"},
         {"amenity", "pub"}, {"amenity", "food_court"}, {"amenity", "biergarten"}
       ]},
    "bar" =>
      {Consensus.Discovery.Provider.Nominatim,
       categories: [
         {"amenity", "bar"}, {"amenity", "pub"}, {"amenity", "biergarten"},
         {"amenity", "nightclub"}
       ]},
    "bowling" =>
      {Consensus.Discovery.Provider.Nominatim, categories: [{"leisure", "bowling_alley"}]},
    "cinema" =>
      {Consensus.Discovery.Provider.Nominatim, categories: [{"amenity", "cinema"}]}
  }
```

The same map is repeated in `config/runtime.exs`'s `ASSIST_LIVE=1` block. An empty
category list answers `{:ok, []}` without a request, the same refusal Overpass makes
today.

`cache_policy/0`: `%{ttl_ms: 24h, error_ttl_ms: 1 min, may_store_results?: true}`.
`location_mode/0`: `:required`. `attribution/0`: unchanged, the same pre-split ODbL line.

### 1.7 Mapping a Nominatim element to `Result`

| `Result` field | Source |
|---|---|
| `name` | `name`, trimmed. Blank → drop the element. |
| `website_url` | First **valid** of `extratags.website`, `extratags["contact:website"]`, `extratags.url`. Valid means absolute `http(s)` with a host that passes `LinkPreview.check_host/1` (trap J, D-052 §3), checked exactly as Overpass checks it today. Invalid → `nil`, never drop. |
| `address` | `"#{house_number} #{road}"`, or `road` alone, from `address`. Same rules as today's `address/1`. |
| `chips` | `[{"cuisine", first value}]` from `extratags.cuisine`. Same rules as today's `chips/1`. |
| `external_ref` | `"#{osm_type}/#{osm_id}"`. |
| `source` | `:osm`. |

Lat/lon, `display_name`, `importance`, `place_id` and the phone/email/hours tags are
**read past, never mapped**. `Result` still has nowhere to put them (the licence
firewall, D-052 §4).

The `check_host/1` export pin in `overpass_test.exs` moves to `nominatim_test.exs`. It
is the reason the function is public, and the pin must not leave with the adapter it
was written for.

### 1.8 The geocoder gets a country bias

`Geocoder.request_url/1` adds `countrycodes=<configured list>`.

**Settled (owner, 2026-10-25): the default is `"us"`.** `config :consensus,
Consensus.Discovery.Geocoder, countrycodes: "us"`, with `nil` meaning no restriction.
This is one deployment for one circle of friends, and widening it (`"us,ca"`) is a config
change. Deriving the country from the browser's time zone (D-055 already receives it) was
considered and rejected: it needs a zone→country table the app doesn't have and adds a
parameter to the async geocode for little gain.

**Not in scope: groups that already stored a wrong area.** The prompt never re-asks once
a group has an area (D-052 §5), and there is no "change area" control. The geocode cache
is ETS, so the deploy clears it for *new* areas. A group already pointed at Liguria stays
there until it is published. Any such group is a draft in progress, since areas are
draft-gated. Fixing that is a UI change and its own small plan (§8).

### 1.9 Telemetry stays provider-neutral

D-056's `provider_request` span keeps its event names. Its `:start` metadata drops `:ql`
(Overpass-only). The handler line changes from `overpass ql=…` to
`provider <Module> repro <url>`, with the URL built by `Nominatim.request_url/1`. That is
D-056 §4's rule unchanged: the module that sends the request builds the logged URL.
`telemetry_test.exs`'s `overpass-api.de` assertion moves to the Nominatim URL. Stop
metadata keeps `status`/`count`/`reason`, and gains **`filtered`**: the number of results
dropped by the category allowlist. That is the field that answers "Nominatim found it,
so why didn't I see it?".

---

## 2. Data model

**No migration.** `search_area`/`search_bbox` keep their format and meaning. No column,
table or persisted field changes. The URL-only retention boundary is unchanged.

## 3. API surface

| Module | Change |
|---|---|
| `Consensus.Discovery` | none (`search/3`'s arity is pinned by invariant 12's test) |
| `Consensus.Discovery.Provider` / `Result` / `Area` | none |
| `Consensus.Discovery.Nominatim` (+ `.HTTP`, `.HTTP.Req`, `.Gate`) | **new** |
| `Consensus.Discovery.Provider.Nominatim` | **new** |
| `Consensus.Discovery.Geocoder` | uses `Nominatim`; adds `countrycodes`; `request_url/1` kept |
| `Consensus.Discovery.Provider.Overpass` (+ `.HTTP`, `.HTTP.Req`) | **deleted** |
| `Consensus.Discovery.Telemetry` | provider line (§1.9) |
| `Consensus.Application.children/0` | + `Nominatim.Gate` after `Discovery.Cache` |
| `config/{config,runtime,test}.exs` | registry (§1.6), HTTP seam, gate interval, `countrycodes` |
| `Consensus.Dev.ScriptedProvider` | none (it is registered by key, and dev without `ASSIST_LIVE` is unchanged) |

## 4. Failure modes

Every one of these still renders as **silence** (D-052 §9). Each also gets a distinct log
reason (D-056), because what the user sees and what the operator sees were deliberately
separated.

| Cause | Tag | Cached? |
|---|---|---|
| Gate full (> 3s wait) | `:rate_limited` | no (nothing was asked) |
| HTTP 429 | `:rate_limited` | 1 min |
| HTTP 403 (Nominatim's block for a policy breach) | `{:http, 403}` → `:search_failed` | 1 min |
| Other non-200 | `{:http, status}` → `:search_failed` | 1 min |
| Transport timeout (10s receive, 5s connect) | `:timeout` | 1 min |
| Body not a JSON list | `:malformed` | 1 min |
| Matches, all outside the category list | `{:ok, []}` with `filtered: n` logged | 24h |
| Anything raised | `:search_failed` | 1 min |

**Policy risk, stated plainly.** Nominatim is a volunteer service and can block the
app's User-Agent. Repeated identical queries are the documented trigger, and the cache
plus the gate are the defence. A block shows up in the log as a run of `{:http, 403}`.
The organizer sees what they see today: a plain card. As with Overpass, the assist stays
deletable.

## 5. Build order

Each stage leaves `mix precommit` green. This is one deploy: Overpass is removed in the
same push that adds Nominatim, so nothing ships half-swapped. Only the docs pass may land
separately (D-057: docs-only pushes don't deploy).

1. **`Nominatim` client + `Gate`** with the shared HTTP seam and the stub rename. Move
   `Geocoder` onto it and add `countrycodes`. Geocoder tests move to the new stub;
   `application_test.exs` asserts the gate's position.
2. **`Provider.Nominatim`**: query building (viewbox reordering, minimum span), element
   mapping, category filter, error taxonomy. Fixture bodies are **recorded real
   responses** (the Zahav, Vernick and Federal Donuts searches from "Why", trimmed), not
   hand-written JSON. Hand-written fixtures are how a parser passes its tests and fails
   its first real page.
3. **Registry swap** in `config.exs` and `runtime.exs`. Delete Overpass, its stub and its
   tests. Move the `check_host/1` export pin.
4. **Telemetry handler** (§1.9) and its tests.
5. **Live evaluation** (§6), then the docs pass (§9).

## 6. Verification

**Unit (`mix test`)**:

- Viewbox ordering and the minimum-span widening, pinned with numbers.
- The category allowlist: a `cafe` dropped under `bar`, kept under `restaurant`, with the
  `filtered` count reported.
- `website_url`: first valid wins; a `localhost`/private-IP website nulls the field and
  keeps the result.
- The gate: back-to-back reservations are 1 000 ms apart; a reservation past
  `max_wait_ms` returns `:busy`; a cache hit makes no reservation.
- The geocoder sends `countrycodes`, and `nil` config sends none.
- `options_assist_test.exs` passes **unchanged**. It runs against `DiscoveryStub`, so a
  diff there means this plan touched the UI contract, which it must not.
- `activity_type_invariant_test.exs` passes unchanged (config is not under `lib/`).

**Live evaluation (the acceptance gate).** `scripts/lookup_eval.exs`, run with
`ASSIST_LIVE=1 mix run scripts/lookup_eval.exs`, calls `Consensus.Discovery.search/3`
through the real registry, cache and gate. Each fixture is `{type, area string, typed
name, expected OSM name}`, against two areas: Philadelphia and Fishtown. It prints the
hit rate. The script is committed so the next provider change re-runs the same set.

- Ship bar: **≥ 7 of the 9 names in the "Why" table hit for `restaurant`**. `Dizengof` and
  `dinner at Zahav` are expected misses (§8).
- Before swapping, run the script once against Overpass and record the number in D-059,
  so the decision rests on a measurement rather than this plan's account of one
  afternoon.

**Production, after deploy.** Add three options on a real draft group. Then
`fly logs | grep '\[lookup'` should show `search … cache=miss -> ok count=N`, with
`provider … repro https://nominatim.openstreetmap.org/search?…` above it. Paste that
URL to confirm the answer matches.

## 7. Non-goals

- Typeahead or per-keystroke anything. Still forbidden by policy and by D-052 §1.
- Discovery or browse. Trap F's enumeration warning still applies.
- Any commercial provider (D-052 §2).
- Ratings, prices, photos or distance on the suggestion row.

## 8. Follow-ups, deliberately left out

- **Photon as a no-match fallback.** It caught "Joes Pizza" → "Joe's Pizza" where
  Nominatim didn't. It is also volunteer-run ("extensive usage will be throttled", no
  SLA), and a second provider per type means a registry change: an ordered list instead
  of one `{module, opts}`. **Deferred by the owner, 2026-10-25**: a miss costs nothing
  but the suggestion, because the typed card and a pasted link still work. Revisit once
  the eval script shows how many misses it would actually recover.
- **Query cleanup** ("dinner at Zahav", trailing "restaurant"). That is a heuristic over
  free text, and it should be built against misses logged in production rather than
  guessed.
- **A "change area" control**, for groups already stored with a wrong area (§1.8).
- **The self-hosted / Overture index** (research Stage 3), still the destination.

## 9. Docs pass (same change, per CLAUDE.md's working agreements)

- `docs/decisions.md`: append **D-059** with the "Why" measurement and §6's before/after
  eval numbers. Amend **D-052 §3** in place: the Overpass adapter bullet becomes history,
  and "Overpass first, Overture the destination" becomes "Nominatim first …". Amend
  **D-056 §4–5** (the Overpass `repro`/QL lines). Grep the file for `Overpass`,
  `overpass_http_stub`, `tags:` and `build_ql`.
- `CLAUDE.md`: narrative header (the "one Overpass/OSM adapter with different tag lists"
  sentence), the repo-layout tree (`discovery/provider/overpass.ex`, the stubs,
  `discovery/nominatim.ex`), invariant 12's "four activity types … resolve to the *same*
  Overpass module" sentence, the `.claude/launch.json` description of
  `consensus-dev-live`, and the test count.
- `README.md`, `TODO.md`, `.claude/skills/*/SKILL.md`: `grep -rn -i overpass` and fix
  every hit.
- `dev/support/scripted_provider.ex` moduledoc and `config/dev.exs` comments that say
  "the real Overpass adapter".
- `docs/research/activity-discovery.md`: leave as written (D-052 set that precedent).
  D-059 is where the provider changed.
