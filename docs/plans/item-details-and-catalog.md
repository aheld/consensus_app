# Plan — item details, a shared catalog searched before Nominatim, and an admin items view

Status: **Approved, 2026-10-25. Built 2026-10-25 (stages 1–5 and 7; stage 6 not built),
uncommitted; recorded as D-060.** The second authorization review changed four §3 rules,
recorded in D-060: only *shared* links keep a row alive; a withdrawn row passes to another
sharer re-snapshotted; a Save that turns sharing off unshares before writing; an unlocated
row is excluded inside a group area. Earlier status, kept for the record: stages 1 and 2
done (2026-10-25), uncommitted; stage 3 (the catalog) next. The `t7` frame review (Pause C) produced seven
owner rulings, recorded in `docs/design/DESIGN-SPEC.md`'s `t7` section; the two that change
this plan are that the `05` row is **Call · Directions** (no Website button — the existing
tangerine **View … →** is the website, §1.7) and that Directions falls back to an
openstreetmap.org address search when there is an address but no location (§1.6). Stage 2
added `Activities.update_activity_and_details/3` (`02b`'s draft Save as one write) and
`Geocoder.geocode_point/1`, and lets `GroupLive.Options` mount the editor, locked, for a
`:voting`/`:completed` group (§1.4). Stage 1 deviated from the text below in two
places, both recorded here: (1) `catalog_item_id` moves to stage 3's `catalog_items`
migration, since it references a table that does not exist until then, so
`add_details_to_activities` adds six columns, not seven; (2) **Use this** is one write,
`Activities.adopt_lookup_result/3` (name + details + `osm_ref` through
`Activity.lookup_changeset/2`, behind the frozen-pool check because it renames), not
`update_activity_details/3` plus a separate name update — one broadcast, and no
half-applied suggestion. `update_activity_details/3` follows `update_activity/3`'s shape
(the two-clause `authorize_activity/2` re-read), since an `%Activity{}` carries no owner. Records as **D-060** when it lands. It
**reverses D-052 §4's URL-only retention boundary** (and research §4.1's "do not add
`lat`/`lon`"), so it must amend D-052 §4, the `Consensus.Discovery.Result` moduledoc and
D-059 in place (see §10). All seven owner decisions in §9 are settled (2026-10-25): Q6 by
explicit choice, the other six by accepting the recommendation. The plan below is written
to those answers. **The build stops twice for design input** (§12): once to hand the owner
the Claude Design prompt (§12.2), and again before any UI code if the returned frame
conflicts with the plan.

**What this builds, in three parts.**

1. **Details on every item.** Every option (`activities` row) can carry a **website, phone,
   address, location and a category** (cuisine, for dining). They are filled at lookup time
   when the organizer taps **Use this**, and editable afterwards on `02b`.
2. **A shared catalog searched before Nominatim.** A **Let anyone find this** toggle on the
   `02b` editor copies an item's details into a `catalog_items` table. The Assisted Add asks
   the catalog first, and only asks Nominatim when the catalog has no match.
3. **An admin items view.** `/admin/items` lists every catalog entry and every item in every
   group, and lets an admin edit them, plus hide or delete catalog entries.

**Why.**
- **PRD invariant 5** ("the session ends in an action"). A winner card with a phone number,
  a map link and a website is the action. Today the app stores none of those, so the card
  can only link to whatever page enrichment found.
- **PRD "Creating a session"** asks that adding a known option be quick. Every Nominatim
  miss (D-059: `Joes Pizza`, a typo, a place OSM lacks) can be fixed once by the organizer
  who knew the answer, and found by everyone after that. Nominatim also allows one request a
  second and is a volunteer service, so each catalog hit is a request we don't send.
- **Operations.** There is no way today to see or correct what organizers have built.

Read first:
- **D-052**, especially §4 (the retention boundary this reverses) and §9 (failure is
  silence; zero keystroke requests);
- **D-059** (the provider, the gate, the registry shape);
- **D-037** / invariant 16 (the frozen pool);
- invariant 1 (admin authorization in three places) and invariant 11 (no `maxlength`);
- invariant 12 (activity type is data; the source pin's regexes, §3.4);
- invariant 18 (16px inputs);
- research §4.1 and trap I (ODbL and storage).

---

## 1. Decisions this plan makes

### 1.1 The retention boundary becomes a per-provider declaration, not an absence of columns

D-052 §4 made it *impossible* to store a commercial provider's forbidden fields by giving
the schema nowhere to put them. That was the right firewall while the candidate providers
included Google and Yelp. D-052 §2 has since rejected every commercial provider on its
terms, and the only live source is OSM (ODbL: storage permitted, attribution required).
Adding columns therefore loses the structural guarantee. The guarantee moves into data:

- `Consensus.Discovery.Provider` gains a callback, `retained_fields/0`. It returns the
  `Result` fields that may be persisted, from
  `[:name, :website_url, :phone, :address, :latitude, :longitude, :category]`.
  `Provider.Nominatim` returns all of them.
- `Consensus.Discovery` stamps each `Result` with a `retainable` list from that callback.
  The only code that turns a `Result` into attrs, `Result.persistable_attrs/1`, reads
  nothing else.
- `Consensus.Discovery.Cache`'s boot-time validation (the `may_store_results?` refusal)
  also refuses a provider that declares a field outside that list.

A future provider whose terms forbid a field omits it. It keeps working, with that field
displayed and never stored, which is exactly what D-052 §4 promised. **Never add
`rating` or `price`** still holds; those fields have no column and are not in the list.

### 1.2 The columns are generic; "cuisine" is the dining *label* for a generic `category`

Invariant 12 says that when per-type data diverges (cuisine vs. genre), that is a schema
decision to make deliberately. This plan makes it: **one nullable `category` string on
`activities`**, holding "israeli" for a restaurant, "bowling alley" for bowling, and later
"drama" for a film. What the field is *called* in the UI is registry data, not a branch:

```elixir
"restaurant" => {Consensus.Discovery.Provider.Nominatim,
                 categories: [...], category_tag: "cuisine", category_label: "Cuisine"},
"bowling"    => {Consensus.Discovery.Provider.Nominatim,
                 categories: [{"leisure", "bowling_alley"}], category_label: "Kind"}
```

- `category_tag` names the extratag the adapter reads (`cuisine`). Without it, the
  adapter humanises Nominatim's `type` ("bowling_alley" → "bowling alley").
- `category_label` is read by `Consensus.Discovery.category_label_for/1` with `Map.get/3`,
  the same shape as `attribution_for/1`.
- A type with no provider gets the default label "Kind". *(§9 Q3, settled: generic
  `category`, not a literal `cuisine` column.)*

### 1.3 Website is `source_url`; location is two floats; address is one display line

| Detail | Column | Shape and validation |
|---|---|---|
| Website | **`source_url`, unchanged** | Already exists. A lookup sets it to the venue's website, and Refetch already re-enriches from it. A second `website_url` column would hold the same URL twice. *(§9 Q2, settled.)* |
| Phone | `phone :string` | Up to 32 characters; only digits, spaces and `+ ( ) - .`; at least 7 digits. Stored as typed. It renders as a `tel:` link built from `+` and digits only, so stored text never reaches an `href` raw. |
| Address | `address :string` | One human line, e.g. "237 Saint James Place, Philadelphia". Capped at 200 graphemes in the changeset, with a counter and **no `maxlength`** (invariant 11). Not structured: one reader, one writer, and nothing queries by street. |
| Location | `latitude :float`, `longitude :float` | Both or neither, within −90..90 / −180..180, rounded to 7 decimals (OSM precision). Used for an "Open in Maps" link, catalog matching (§3.3) and future distance. |
| Category | `category :string` | Up to 60 graphemes, counter, no `maxlength`. |
| Provenance | `osm_ref :string` | `"node/6374481270"`; nullable. Used to deduplicate the catalog and to decide whether the ODbL credit is owed for an item's details (§1.7). Displayed never. |
| Shared link | `catalog_item_id` | FK to `catalog_items`, `ON DELETE SET NULL` (§3). |

All columns are nullable and added with `ALTER TABLE ADD COLUMN`, which SQLite accepts
without a table rebuild (sqlite skill). `Activity.changeset/2` does **not** cast them. A
new `Activity.details_changeset/2` casts exactly
`[:source_url, :phone, :address, :latitude, :longitude, :category]`. That keeps the two
write paths separate (§1.4) and stops the name/description form from smuggling details,
or the reverse. It is the same reason `position_changeset/2` is its own function.

### 1.4 Details stay editable after publish; name, description and order stay frozen

Invariant 16 freezes the pool because votes point at it: deleting an option destroys
votes, reordering changes tie-breaks, and renaming changes what people agreed to. A wrong
phone number is none of those, and it matters most *after* the vote, on the winner card.
So:

- **`Activities.update_activity_details/3`** is a new owning function, with a user/anonymous
  head pair delegating to one private body (invariant 1's three rules). It is
  **not** behind `ensure_pool_editable/1`.
  - It is refused for a `:cancelled` group (`{:error, :group_closed}`).
  - It broadcasts `{:activity_updated, activity}`, so open results screens update live.
- `update_activity/3` (name, description, image) keeps its `:pool_locked` refusal unchanged.
- The `02b` editor's Details section is reachable from `03 review` and the organizer's
  `05 results` after publish. The name and description fields stay read-only there.

*(§9 Q1, settled: details are editable after publish. Had the answer been no, details
would have joined the frozen set behind the same `ensure_pool_editable/1` check, and
nothing else in the plan would change.)*

### 1.5 Capture at lookup

- `Result` gains `:phone`, `:latitude`, `:longitude`, `:category` and `:retainable`.
  `:chips` is removed; it carried only cuisine, which is now `:category`.
- `:address` stays as the short street line the suggestion row shows. It gains a sibling,
  `:full_address` (street plus `city`/`town`/`village`), which is what gets stored.
- `Provider.Nominatim` maps:
  - `extratags.phone`, then `contact:phone`, keeping the first that passes the phone rule;
  - `lat`/`lon` (strings in jsonv2, parsed);
  - category per §1.2.
- The suggestion row is unchanged (name + street). **Use this** writes name, `source_url`
  and every retainable detail in one `update_activity_details/3` + name update.
- Enrichment (`LinkPreview`) fills photo and description only. It never writes a detail,
  the same rule as D-052 §6's "enrichment must not overwrite the confirmed name".

**Pasted links (optional stage 6).** `Consensus.LinkPreview.JsonLd` already parses
`schema.org` nodes. A `Restaurant`/`LocalBusiness` node carries `telephone`, `address`,
`geo` and `servesCuisine`. Stage 6 fills those details **only where the item's details
are empty**, so a pasted link never overwrites what an organizer typed or confirmed.

### 1.6 Editing on `02b`

A **Details** section is added below the description, inside the existing form card:

- **Website.** The existing `source_url` line becomes editable. Saving a changed URL runs
  the existing `{:refetch, id}` async, so the photo and description follow the new link.
- **Phone, Address, Category.** Plain inputs (16px, invariant 18), with counters where
  §1.3 caps them. The category input's label comes from `category_label_for/1`.
- **Location.** No map widget and no raw numbers for organizers:
  - *Located* shows "📍 On the map · Open in Maps · Remove".
  - *Not located* shows **Find from address**, which geocodes the address field through
    `Consensus.Discovery.Geocoder`. That call is gated, cached, and made from
    `start_async` (invariant 13). The geocoder grows a `geocode_point/1` that returns the
    first result's lat/lon rather than a bbox.
  - A failed geocode shows one inline line: "Couldn't find that address." This is the
    first non-silent assist failure, which is deliberate. D-052 §9's silence rule is for
    a lookup the organizer didn't ask for; this is a button they pressed.
- **Let anyone find this.** A toggle, unticked by default (§3.2).

"Open in Maps" is `https://www.openstreetmap.org/?mlat=…&mlon=…#map=18/…/…`: a link
built from two floats, no tiles, no SDK, and no third party learning anything until
someone taps it. *(§9 Q7, settled: openstreetmap.org, not Apple/Google Maps.)*

### 1.7 Where details render, and attribution

- **`02`/`03` cards:** a category chip and the street address under the name.
- **Guest ballot:** category and address only. Phone and website stay off the ballot; the
  ballot is for choosing, not for calling.
- **`05` winner card** (organizer and participant): **Call · Directions · Website**
  buttons. Each appears only when its detail exists. This is the PRD invariant 5 action;
  the booking deep-link (Q-5) stays open and separate.
- **ODbL credit.** Any item whose `osm_ref` is set shows the existing pre-split
  "Places from OpenStreetMap contributors" line wherever its details render. Displaying
  OSM-derived data in a Produced Work keeps the attribution obligation (trap I).

There is no design frame for any of this. **Stage 2 starts with a design pass** in the
linked Claude Design project (the `design-system` skill), not with code. The prompt for
that pass is written out in §12.2, and §12.1 says where the build pauses for it.

---

## 2. Data model — part 1

Migration `add_details_to_activities`: the seven nullable columns in §1.3, plus an index
on `activities(catalog_item_id)`. No backfill: existing rows have no details, which is
the truth. The CI upgrade rehearsal (invariant 10) runs it against a populated volume
automatically.

---

## 3. The shared catalog — part 2

### 3.1 Table

```
catalog_items
  id                       integer PK
  activity_type            string NOT NULL      -- data; the registry key it is searched under
  name                     string NOT NULL
  search_name              string NOT NULL      -- normalised (§3.3), indexed
  description, source_url, phone, address, latitude, longitude, category, image_url   -- as on activities
  osm_ref                  string NULL
  status                   string NOT NULL DEFAULT 'visible'   -- visible | hidden
  shared_from_activity_id  → activities      ON DELETE SET NULL
  shared_by_user_id        → users           ON DELETE SET NULL
  shared_by_anonymous_organizer_id → anonymous_organizers ON DELETE SET NULL
  admin_edited_at          utc_datetime NULL
  use_count                integer NOT NULL DEFAULT 0
  timestamps
  UNIQUE (activity_type, osm_ref) WHERE osm_ref IS NOT NULL
  INDEX  (activity_type, status, search_name)
```

**`description` is shared** (owner decision, 2026-10-25; §9 Q6). Most descriptions are
the venue's own blurb, filled by `LinkPreview`, and for an item with no website the
description may be the only information there is. The cost is that a personal note
("Mom's favourite, get the hummus") is shared too. The protection is the copy beside the
toggle naming the description explicitly (§3.2), plus the default-off toggle.

**On the anonymous-organizer foreign key.** D-058 made `anonymous_organizers` deletable
only by the boot sweep, whose predicate requires "owns no group". A catalog row is not a
group, so the sweep can delete an identity that shared something. `SET NULL` keeps the
catalog row and drops only the provenance.

Context: **`Consensus.Catalog`**, a sibling of `Activities`, not a part of it. The
catalog is read by people who own nothing in it.

### 3.2 Sharing semantics: a snapshot, not a live reference

- **Toggling on** calls `Catalog.share_activity/2` (an owning function with an
  anonymous/user head pair):
  - It upserts a catalog row from the activity's name and details.
  - Deduplication: first by `(activity_type, osm_ref)`, then by `(activity_type,
    search_name)` *and* coordinates within ~50 m.
  - It sets `activities.catalog_item_id`. It is allowed at any group status, since it
    does not change the activity.
- **A row this activity created** (`shared_from_activity_id`) follows the activity's
  later detail edits, **unless an admin has edited the row** (`admin_edited_at` set).
  From then on the admin's version wins and organizer edits stop syncing.
- **A row the share deduplicated into** (someone else's) is linked, not overwritten. One
  organizer's edit never rewrites a row another organizer created.
- **Toggling off** unlinks the activity. If this activity created the row and nothing
  else links to it, the row is deleted; otherwise it is left for the others.
- **Using a catalog result** in another group copies the fields into that group's
  activity, sets `catalog_item_id` and bumps `use_count`. That group's later edits stay
  local unless that organizer shares too.

The editor shows exactly what will be shared: "Shares the name, **description**, website,
phone, address, location, category and photo, so anyone planning nearby can find it."
The word *description* is the one to keep when this copy is edited, since it is the only
free-text field and the only one an organizer might not expect to be public. There is
**no "shared" indicator to guests**.

**Privacy guard.** The toggle is disabled until the item has a website, an address or a
location. A bare typed name ("Grandma's") has nothing anyone else could find. Beyond
that, the default-off toggle and the copy above are the protection.

### 3.3 Matching

The catalog is small (hundreds to low thousands of rows on one machine), so v1 is a
plain indexed query, not FTS5:

- **Normalisation** (`Catalog.search_name/1`, one function used for both stored names and
  queries): lowercase, Unicode NFD with combining marks stripped, `&` → `and`,
  apostrophes deleted, every other non-alphanumeric character → space, whitespace
  collapsed.
  - "Joe's Pizza" → `joes pizza`, which fixes the `Joes Pizza` miss D-059 recorded, for
    shared items.
  - "Café La Maude" → `cafe la maude`.
- **A match** means every query token is a prefix of some name token, in any order.
  "beddia pizzeria" therefore matches `pizzeria beddia`. A `LIKE '%token%'` per token
  narrows the rows in SQL; the prefix-and-order check runs in Elixir on that short list.
- **Geography.**
  - When the group has an area and the row has coordinates, the row must fall inside the
    area's bbox, widened as D-059 §6 does.
  - Rows **without** coordinates match only on an exact normalised name, and rank last.
    A "Joe's Pizza" in another city with no location must not outrank a local one.
  - With no group area, every visible row of the type is eligible.
- **Ranking:** exact name first, then prefix, then `use_count` descending. At most 3, as
  always.
- **Upgrade path.** If the table grows past what a scan answers in a few milliseconds,
  add an FTS5 virtual table. The research Stage 3 Overture extract is the *same row
  shape* (name, category, lat/lon, website, address) and can land in this table with an
  `overture_ref`. **The catalog is the local index the research wanted**, seeded by
  organizers first.

### 3.4 How the lookup reaches it: the registry entry becomes an ordered list

```elixir
"restaurant" => [
  {Consensus.Catalog.Provider, activity_type: "restaurant"},
  {Consensus.Discovery.Provider.Nominatim, categories: [...], category_tag: "cuisine", ...}
]
```

- `Consensus.Discovery` tries providers in order. The **first `{:ok, [_ | _]}` wins and
  the rest are never called**, so a catalog hit sends no Nominatim request.
- `{:ok, []}` and every error fall through to the next provider. Only when the last
  provider fails is that failure returned (still silence).
- A bare `{module, opts}` entry still means a one-element list, so test and dev configs
  keep working. This is the same change D-059 §8 said Photon would need, made once.
- **`Catalog.Provider`:**
  - `cache_policy/0` returns `ttl_ms: :none`. It is a local query, and an admin hide must
    take effect on the next search.
  - `location_mode/0` returns `:optional`.
  - `retained_fields/0` returns everything in §1.1.
  - Results carry `source: :catalog`, plus `osm_ref` when the row has one.
- **Attribution becomes per result set.** `attribution_for/1` becomes
  `attribution_for(type, results)`, returning the OSM line when any result is OSM-derived
  (`source: :osm`, or a catalog row with an `osm_ref`). A catalog answer made entirely of
  organizer-entered rows shows none.
- **Invariant 12.** The catalog filters by type with a keyword filter,
  `where(CatalogItem, activity_type: ^type, status: "visible")`. That is data, and it
  does not trip the source pin's comparison regex
  (`activity_type\s*(==|!=)` in `activity_type_invariant_test.exs`).
  - Three new files mention `activity_type` and join the allowlist deliberately:
    `catalog.ex`, `catalog/catalog_item.ex` and `catalog/provider.ex`.
  - Write `c.activity_type == ^type` and CI fails, as intended.
- **Telemetry (D-056).** The search span's start event lists the chain
  (`providers=Catalog,Nominatim`). The stop event adds `answered_by=Catalog`. The
  `provider_request` span stays Nominatim's. A catalog hit therefore reads as
  `search … answered_by=Catalog` with no `repro` line under it, which is correct, since
  nothing was requested.

---

## 4. The admin items view — part 3

**Route:** `live "/admin/items", AdminLive.Items, :index`, inside the existing
`scope "/admin"` + `live_session :require_admin` (invariant 1). `router_test.exs` finds
admin routes by scanning, so it asserts both guards on the new route with no new code.
There is a cross-link from `/admin/users`, next to the feedback link. The header's `⋯`
menu still has no admin entries, as CLAUDE.md records.

**Two tabs on one LiveView** (`?tab=catalog|items`, patched):

| Tab | Rows | Columns | Actions |
|---|---|---|---|
| **Catalog** | every `catalog_items` row, newest first, streamed; filter by type, status and a name search (`search_name`) | name, type, category, address, has-location, source (OSM / organizer), sharer (username, or "No account"), uses, status | **Edit** (all fields, raw lat/lon allowed), **Hide/Unhide**, **Delete** |
| **All items** | every `activities` row across all groups, newest first; filter by group status, "has details", "shared" | name, group title (links to nothing; admins have no organizer screens for other people's groups), group status, organizer label (`OrganizerLabel`), details summary, shared? | **Edit details**, **Share to catalog** |

**Editing.** Edit opens an inline form, the same pattern as `AdminLive.Feedback`'s note.

- `Catalog.admin_update/3`, `admin_set_status/3` and `admin_delete/2` match
  `%Scope{user: %User{is_admin: true}}` **in the function head**. Invariant 1 says that
  is the right shape for an admin write, and this would be its first living example
  again since D-027.
- `admin_delete/2` also re-reads the actor's role inside `Repo.transact`, the
  `ensure_actor_is_admin/1` idiom, because it is destructive. It needs no sudo gate:
  nothing cascades, since `activities.catalog_item_id` is set to null, and every group's
  copy survives.
- **Activities, from the admin side:** `Activities.admin_update_activity_details/3`,
  admin head match, details only. **Admins cannot rename, reorder or delete another
  organizer's options.** Invariant 16's reasons apply to admins too, and a delete would
  cascade votes.
- **Audit lines** in `Consensus.Accounts`' `[audit]` shape, so `fly logs | grep audit`
  stays the one record of admin writes: `[audit] catalog_edit|catalog_hide|
  catalog_unhide|catalog_delete|activity_details_edit actor_id=… target_id=…`.

**Not built:** merging duplicate catalog rows, bulk actions, CSV export. They are
follow-ups once the table has enough rows to need them.

---

## 5. API surface

| Module | Change |
|---|---|
| `Consensus.Activities.Activity` | + 7 fields, + `details_changeset/2`; `changeset/2` unchanged |
| `Consensus.Activities` | + `update_activity_details/3` (pair), + `admin_update_activity_details/3`, + `list_all_activities_for_admin/2` |
| `Consensus.Catalog` (+ `CatalogItem`, `Provider`) | **new** |
| `Consensus.Discovery` | ordered provider lists; `attribution_for/2`; `category_label_for/1`; stamps `retainable` |
| `Consensus.Discovery.Provider` | + `retained_fields/0` callback |
| `Consensus.Discovery.Result` | + `:phone :latitude :longitude :category :full_address :retainable :osm_ref`, − `:chips`, + `persistable_attrs/1` |
| `Consensus.Discovery.Provider.Nominatim` | maps phone, lat/lon, full address, category; honours `category_tag` |
| `Consensus.Discovery.Geocoder` | + `geocode_point/1` |
| `Consensus.Discovery.Cache` (boot validation) | refuses undeclared retained fields |
| `ConsensusWeb.GroupLive.Options` | Details section, share toggle, Use-this writes details |
| `ConsensusWeb.GroupLive.Results`, `JoinLive.Results`, `JoinLive.Ballot`, cards | render details; Call/Directions/Website |
| `ConsensusWeb.AdminLive.Items` | **new** |
| `ConsensusWeb.PrivacyLive` | states the new storage and what sharing publishes (it "states only what the code does") |
| `config/{config,runtime}.exs` | registry lists + `category_tag` / `category_label` |

## 6. Failure modes

| Case | Behaviour |
|---|---|
| Catalog query raises | Rescued inside `Catalog.Provider`, logged, falls through to Nominatim. The assist behaves exactly as today. |
| Catalog hit is wrong (stale phone, closed place) | The organizer edits their copy. An admin edits or hides the row. Nothing propagates to groups that already copied it (snapshot, §3.2). |
| Spam or abusive shared row | Visible only to someone who types a matching name in the same area. An admin hides it, effective on the next search (no cache). Sharer provenance is on the row. |
| Someone shares a private address | Default-off toggle, explicit copy, toggle disabled for bare names; unsharing deletes a sole-owned row; an admin can delete. Residual risk accepted (§9 Q5, settled). |
| Find from address fails | One inline line on `02b`; location stays empty. |
| Phone fails validation | Changeset error on the field; nothing saved. |
| A provider declares a non-retainable field | Boot refuses, like `may_store_results?: false`. |
| Group cancelled | Detail edits refused (`:group_closed`); sharing still allowed (it does not change the group). |
| Admin edits a row an organizer also edits | `admin_edited_at` stops sync from organizers; the admin's version wins. |

## 7. Build order

Each stage leaves `mix precommit` green. Stages 1–2 ship together (details are captured
only if they can be seen and fixed). Stages 3–4 ship together (a share that nothing
searches is a promise the app doesn't keep). Stage 5 can ship alone.
Which model runs each stage, and every subagent it spawns, is set in §11; follow it
rather than letting agents inherit the session's model.

0. **⏸ PAUSE A — hand over the design prompt.** Before writing any code, print the §12.2
   prompt for the owner and stop for that turn. Stage 1 needs no design, so the next turn
   continues with it while the owner runs the prompt.
1. **Details schema and capture.** Migration, `details_changeset/2`, `retained_fields/0`
   and boot validation, the `Result` fields, Nominatim mapping (extend the recorded
   fixtures, which already carry phone and lat/lon), and **Use this** writing details.
2. **Design review, then UI.**
   - **⏸ PAUSE B — wait for the frame.** If the owner has not yet said the `t7` frame is
     done, stop after stage 1 and ask for it. Do not start any template work without it.
   - Pull the frame and review it against §12.3. If it conflicts with the plan or an
     invariant, list the conflicts and **stop for the owner's call** (§12.1).
   - Then build the `02b` Details section, the card/ballot detail line and the `05`
     action row from the frame, plus `update_activity_details/3`, Find from address and
     the ODbL credit on OSM-derived items.
3. **Catalog.** Migration, `Consensus.Catalog`, normalisation, share/unshare/sync rules,
   and the toggle on `02b`, built from the same `t7` frame (it draws the toggle, §12.2).
4. **Catalog in the lookup.** Ordered registry, `Catalog.Provider`, per-result-set
   attribution, telemetry `answered_by`, and the invariant-12 allowlist additions.
5. **Admin `/admin/items`.**
6. *(optional)* **JSON-LD details on pasted links**, fill-if-empty.
7. **Docs pass** (§10).

## 8. Verification

**Unit / LiveView (`mix test`):**
- `details_changeset/2`: phone charset and digit count; lat/lon both-or-neither and
  ranges; address and category grapheme caps; `changeset/2` cannot set a detail and
  `details_changeset/2` cannot set a name.
- Nominatim mapping from the recorded fixtures: Zahav's phone, coordinates, full address,
  `israeli`.
- `update_activity_details/3`: both heads; cross-tenant refusal both ways; allowed in
  `:voting` and `:completed`; refused in `:cancelled`; broadcasts.
- Use this persists every retainable field. A provider stub that retains only
  `[:name, :website_url]` persists nothing else (the firewall test).
- Boot refuses a provider declaring an unknown retained field.
- Normalisation: `Joe's Pizza` ↔ `joes pizza`, word order, accents, `&`.
- Catalog matching: bbox inclusion and exclusion, the unlocated-exact-name rule, ranking,
  `hidden` excluded.
- Ordered registry: a catalog hit makes **zero** Nominatim requests (stub plus
  `Gate.granted/0`); a catalog `{:ok, []}` or error falls through; a bare tuple still
  works.
- Share: upsert, dedupe by `osm_ref`, dedupe by name + distance, sync after edit,
  `admin_edited_at` stops sync, unshare deletes only a sole-owned row; the toggle is
  disabled for a bare name; the description is copied, and the share copy names it.
- Admin: head-match refusal for a non-admin (`FunctionClauseError`); delete re-reads the
  actor; admins cannot reach `update_activity/3` or `delete_activity/2` on others'
  groups; audit lines emitted; `router_test.exs` covers the new route.
- `options_assist_test.exs`: existing assertions pass unchanged, and new ones cover the
  details path.
- `activity_type_invariant_test.exs`: green with exactly the three allowlist additions.

**Live:** `scripts/lookup_eval.exs` gains a catalog section. It seeds a throwaway
catalog row ("Joe's Pizza", in Philadelphia) in the dev database, asserts the `Joes Pizza`
row now hits with `answered_by=Catalog` and that no Nominatim request was made, then
deletes the row.

**Production, after deploy:**
1. Add an option via lookup; confirm its phone and address on the card and on the `05`
   action row.
2. Share it from a second browser's session.
3. Type the same name in a new group and confirm `answered_by=Catalog` in
   `fly logs | grep '\[lookup'`.
4. Hide the row in `/admin/items`; repeat the search and confirm it falls through to
   Nominatim.

## 9. Owner decisions (all settled 2026-10-25)

Q6 was decided explicitly; the owner accepted the recommendation for the rest.

| # | Question | Decision |
|---|---|---|
| Q1 | May organizers edit **details** after the vote opens? | **Settled: Yes** (§1.4). The phone number matters most on the winner card. Name, description and order stay frozen. |
| Q2 | Is "website" the existing `source_url`, or a new column? | **Settled: `source_url`** (§1.3). For a venue they are the same URL. |
| Q3 | Generic `category` with a per-type label, or a literal `cuisine` column? | **Settled: Generic `category`** (§1.2). Invariant 12 says a cuisine column is a polymorphism decision; this is the version that doesn't need another one for films. |
| Q4 | On a catalog hit, skip Nominatim entirely, or merge both? | **Settled: Skip** (§3.4). It saves the request, and the organizer can dismiss and edit. Merging can come later. |
| Q5 | Can organizers **without an account** share? | **Settled: Yes**, with admin hide as the control. Requiring an account would make sharing the one thing D-058's accountless organizer can't do. |
| Q6 | Is the description shared? | **Settled (owner, 2026-10-25): yes, always** (§3.1), with the share copy naming it. Rejected: never sharing it (it is usually the venue's own blurb, and the only detail for items with no website); sharing it only while unedited (needs a `description_edited_at` marker); a separate checkbox (one more decision on a quick screen). |
| Q7 | "Open in Maps" target? | **Settled: openstreetmap.org** (§1.6): no tracking until tapped, and consistent with the data source. Apple/Google Maps links are a one-line change if preferred. |

## 10. Docs pass (same change, per CLAUDE.md's working agreements)

- **`docs/decisions.md`**
  - Append **D-060**.
  - Amend **D-052 §4** in place: the URL-only boundary becomes per-provider
    `retained_fields/0`. D-052 §4's paragraph becomes history; "never `rating`/`price`"
    stays an instruction.
  - Amend **D-052 §3** (the registry value is an ordered list) and **D-059 §5** (the same).
  - Amend **D-056** (`answered_by`, the providers list).
  - Amend **D-037**'s consequence: details are outside the frozen set.
  - Grep for `URL-only`, `chips`, `retention` and `attribution_for`.
- **`Consensus.Discovery.Result` moduledoc:** rewrite its "licence firewall" paragraph to
  describe `retained_fields/0`.
- **`CLAUDE.md`**
  - the narrative header;
  - the repo-layout tree (`catalog.ex`, `catalog/`, `admin_live/items.ex`, the migration);
  - **invariant 16**: details are deliberately outside it, and say why;
  - **invariant 12**: the three allowlist additions and the generic `category`;
  - **invariant 1**: the catalog admin writes revive the head-match example;
  - invariant 5's cascade paragraph: `catalog_items` survive a user's deletion, with
    provenance nulled;
  - the test count.
- **`README.md`**, **`TODO.md`** and `.claude/skills/*`: grep for every route, function
  and count touched.
- **`/privacy`**: the page states what is stored, so it must name phone, address and
  location, and say that sharing publishes them.
- **`docs/research/activity-discovery.md`**: leave as written (D-052's precedent).
  D-060 is where the boundary moved.

## 11. Models and agent cost

The build runs in Claude Code. Every agent it spawns — Agent-tool subagents, Workflow
agents, review refuters — **gets an explicit `model`, and an explicit `effort` where the
tool takes one**. Nothing inherits the session model by default. This section is the
standing instruction that makes setting `effort` on a subagent legitimate (the Agent tool
only allows it when instructions ask for it). The rule comes from 2026-10-23: a
150-agent review of the accountless-organizer plan, every agent inheriting Opus, used 87%
of the owner's usage and hit the session limit mid-run.

### 11.1 Prices this is based on

Per million tokens, from the `claude-api` skill's model table (cached 2026-10-06; check
before relying on it):

| Model | Input | Output | Cache read | Default effort |
|---|---|---|---|---|
| Fable 5.1 | $10.00 | $50.00 | $0.25 | — |
| Opus 5.5 | $4.00 | $20.00 | $0.20 | `medium` |
| Sonnet 5.5 | $2.00 | $10.00 | $0.20 | `high` (set it explicitly) |
| Haiku 5.5 | $0.10 | $0.50 | — | `medium` |

**This repo's sessions are dominated by cached input.** CLAUDE.md alone is a very large
prefix re-read on every turn. Opus 5.5 and Sonnet 5.5 cost the **same** for a cache read,
so in a long session the Opus premium is only in output and fresh input, well under the
2× the headline prices suggest. That is why the invariant-heavy stages below stay on
Opus: a wrong ownership head or a broken retention boundary costs more to find and
unwind than the output tokens saved. Judge cost per completed stage, not per request.

### 11.2 Per stage

| Stage | Main session | Effort | Why |
|---|---|---|---|
| 1 Details schema and capture | **Opus 5.5** | `medium` | Reverses D-052 §4; new changeset split; `retained_fields/0` and the boot refusal. Most invariants touched per line. |
| 2a Design review (§12.3) | Opus 5.5 | `medium` | The owner runs the §12.2 prompt in Claude Design. The session's job is to review the returned frame against the checklist, which takes judgment and produces little output. |
| 2b UI build | **Sonnet 5.5** | `medium` | LiveView and HEEx work against an approved frame, following patterns already in `options.ex`. `update_activity_details/3`'s head pair stays with stage 1's Opus session or gets the Opus review below. |
| 3 Catalog context and sharing | **Opus 5.5** | `medium` | Ownership head pairs, sync and dedupe rules, three foreign keys with deliberate delete behaviour. |
| 4 Catalog in the lookup | **Opus 5.5** | `medium` | Changes `Discovery`'s contract and touches the invariant-12 source pin. |
| 5 Admin view | **Sonnet 5.5** | `medium` | Mostly the `AdminLive.Feedback` pattern again. The admin-scope context functions get one Opus review (below). |
| 6 JSON-LD details (optional) | Sonnet 5.5 | `medium` | Extends an existing parser with fill-if-empty rules. |
| 7 Docs pass | Sonnet 5.5 | `medium` | Grep-and-fix sweep plus D-060. One Opus read of the D-060 draft only, since it is the authoritative record. |

**Fable 5.1 is not used by default.** It costs 2.5× Opus. Escalate to it only when the
same concrete problem has failed twice on Opus 5.5, and ask the owner first.

### 11.3 Subagents and reviews

| Job | Model | Effort | Rule |
|---|---|---|---|
| Locating code, sweeping files (`Explore`) | **Haiku 5.5** | — | It reads excerpts and returns locations, which needs no judgment. |
| Mechanical runs: the eval script, `mix precommit`, the CI watch, log summaries | none — run inline | — | A handful of tool calls; spawning costs more than it saves. |
| Docs grep sweep (§10 lists) | Haiku 5.5 | `low` | Mechanical find-and-list; the main session makes the edits. |
| Code review per shipped pair (`/code-review`) | the skill's default | `medium` | Never `ultra`: it is a billed cloud run and only the owner can launch it. |
| Review refuters / narrow fact-checks | **Sonnet 5.5** | `low` | **Sequential:** one refuter first, a second only if the first refutes. A finding dies only when both refute. |
| Lens reviewers, critics, implementers inside a Workflow | Sonnet 5.5 by default; Opus 5.5 for the auth and retention lenses | `medium` | Keep each workflow under the session's size guideline (medium: fewer than 10 agents). |
| The Opus authorization review (stages 2b and 5) | Opus 5.5 | `medium` | One agent, given the diff of the context functions only, not the conclusion. |

**Workflow scripts** set `model` and `effort` on every `agent(...)` call, and pass large
inputs (this plan, diffs) as a scratchpad file path rather than inline `args`. **No
workflow runs unless the owner opts in.**

### 11.4 Recommended model to start

**Start stage 1 in a fresh session (`/clear`) on Opus 5.5 at `medium` effort.** Stage 1
does the expensive-to-get-wrong part: it reverses a settled decision and sets up the
changeset split, the retention declaration and the boot-time refusal that every later
stage builds on. Because cache reads cost the same as on Sonnet 5.5 (§11.1), Opus costs
little extra there. Switch the session to Sonnet 5.5 (`/model`) at stage 2b, and back to
Opus 5.5 for stages 3–4.


## 12. Design input: the pause points and the Claude Design prompt

### 12.1 When the build stops for design

The design source of truth is the linked Claude Design project
(`claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af`, D-057). Only the owner can run a
prompt there, so the build cannot get a frame by itself. It stops and waits in four cases:

| # | When | What the session does | What resumes it |
|---|---|---|---|
| **A** | Start of the build, before stage 1 | Prints the §12.2 prompt in a fenced block, ready to paste, and ends the turn. | The owner says to continue. Stage 1 then runs while the design is being drawn. |
| **B** | End of stage 1, if the frame isn't done | Says stage 1 is done and asks for the `t7` frame. Writes no template code. | The owner says the frame is ready. |
| **C** | Frame review (§12.3) finds a conflict | Lists each conflict with the plan section or invariant it breaks and a recommended resolution, then ends the turn. It never picks silently. | The owner decides each one. A decision that changes the plan is written back into this file. |
| **D** | During stages 2b, 3 or 6, a state the frame doesn't draw | If it is a direct combination of drawn parts (an empty case of a drawn row, a drawn state on another card), build it and list it in the stage summary. If it needs new visual vocabulary or new copy, stop and ask, and offer a follow-up prompt for Claude Design. | The owner's answer, or a returned follow-up frame. |

**Getting the frame back into the repo.** Read it with `DesignSync` `get_file`, and **check
`truncated`**: the Create & Share file is over the 256 KiB cut-off and comes back cut off
mid-element with no error (D-057 §3). If it is truncated, ask the owner to export the
file, as D-057 did. Save the result under `docs/design/site/` with the preview harness
stripped (D-057 §2). Add a `t7` section to `docs/design/DESIGN-SPEC.md` recording every
deviation the build makes from it, the way the `t5` assist states section does.

**Not designed:** `/admin/items` (stage 5) gets no frame. It reuses
`AdminLive.Feedback`'s layout and the existing table components.

### 12.2 The prompt

Paste this into the linked project's **Consensus · Create & Share** file as a new turn:

````text
New turn: t7 · Item details. Same file, same phone frame, same sticker system as t1–t6.
Draw new panels only. Do not redraw or restyle anything that already exists.

## What's changing

Each option in a pool (a restaurant, for now) can now carry details: website, phone,
street address, a map location, and a category (shown as "Cuisine" for restaurants). Most
of the time the Assisted Add lookup from t5 fills them in when the organizer taps
"Use this". The organizer can also type or fix them on the 02b edit screen. The point is
the end of the flow: once there's a winner, the group should be one tap away from calling,
getting directions to, or opening the website of the place they picked.

There's also a new toggle, "Let anyone find this". It adds the option to a shared list
that the lookup searches first, so the next organizer who types that name nearby gets
these details without having to fix them again.

## Panels to draw (label them t7-a … t7-g)

t7-a · 02b edit an option, before publish, all details filled.
  Under DESCRIPTION, add a DETAILS section inside the same form card:
  - WEBSITE: today's dashed source-link row becomes an editable URL field. Keep the
    Refetch affordance.
  - PHONE: single-line field.
  - ADDRESS: single-line field with a live counter, e.g. 41/200.
  - CUISINE: single-line field with a live counter, e.g. 7/60. The label comes from data;
    for another activity type it would say "Kind", so don't build the layout around the
    word "Cuisine".
  - LOCATION, "located" state: "📍 On the map · Open in Maps · Remove". Never show
    latitude or longitude numbers.
  - Then the share toggle, OFF, with this copy beside it:
    "Let anyone find this — Shares the name, description, website, phone, address,
    location, category and photo, so anyone planning nearby can find it."
    The word "description" must stay visible and must not be truncated or hidden.
  - Last, in DM Mono 9px --faint: "Places from OpenStreetMap contributors". Only the
    contributors phrase is a link. It appears only on items whose details came from OSM.
  - Footer unchanged: Cancel + Save option.

t7-b · 02b, location states. Three crops of the LOCATION row only:
  - not located: a "Find from address" button (secondary, not tangerine);
  - finding: the same button busy;
  - failed: one inline line, "Couldn't find that address.", with the button available
    again. This is the only assist failure that's ever shown, because the organizer
    pressed the button.

t7-c · 02b, share toggle states. Crops of the toggle row only: OFF; ON; and DISABLED
  (the item has no website, address or location yet), with a short line saying why, e.g.
  "Add a website or address first."

t7-d · 02b after the vote has opened, reached from 03 review or 05 results.
  NAME and DESCRIPTION are read-only, styled so they clearly can't be edited without
  looking broken. Photo editing is gone. DETAILS and the share toggle stay editable. Add
  one quiet line explaining why: details can still be fixed, but the options people voted
  on can't change.

t7-e · 02 add options and 03 review cards.
  Under the option name: a category chip (the t5 small-pill convention: 1.5px ink/45
  border) and the street address on one truncating line. Show one card with both, one
  with only an address, and one with no details (today's card, unchanged). Show where the
  OSM credit line goes when a card's details came from OSM.

t7-f · Guest ballot (1c-1 sticker grid, plus one swipe-deck card).
  Category chip + street address only. No phone, no website, no map link: the ballot is
  for choosing, not calling. Must still fit the grid tile without growing it much.

t7-g · 05 results, the winner card (draw the organizer's version and the participant's).
  An action row: Call · Directions · Website. Each button appears only if its detail
  exists. Draw: all three; only Directions; none (the row is absent, not empty). Call is
  a tel: link, Directions opens openstreetmap.org, Website opens the venue's site.
  Include the OSM credit line when the winner's details came from OSM.

## Hard constraints (each comes from a shipped decision; don't trade any away)

- Sticker rules unchanged: 2px ink borders, hard offset shadows, the existing tokens and
  radii, Instrument Sans + DM Mono, press = translate(1px,1px).
- Tangerine is the ONE forward action per screen. On 02b that's Save option. Find from
  address, the toggle and Refetch are not tangerine. On 05, Call / Directions / Website
  are not tangerine unless you deliberately make one of them the screen's single forward
  action. If you do, say so and say what loses tangerine.
- Every input and textarea is at least 16px text. iOS zooms the page on anything smaller.
  This overrides the 13.5px/15px sizes in the original 02b frame. If you need a smaller
  box, change the padding, not the font size.
- No maxlength. Free-text fields show a live counter in the label row, and the counter
  turns tangerine past the limit (the existing 02b description pattern).
- Never show a rating, price band, hours, distance, or a photo from the place provider.
  We don't have the rights to display them.
- No embedded map, map tiles or map SDK. Location is a text state plus a plain
  "Open in Maps" link.
- No upload anywhere. Images stay URL-referenced (Replace asks for an image URL).
- Guests never see a "shared" badge or anything else about the toggle.
- Fields rest on the mint shadow (rule 5). The violet assist accent from t5 is only for
  assist-owned surfaces. The Details fields are not assist surfaces, even when the lookup
  filled them.
- Phone width first, same as every other panel.

## Annotate

Next to each panel, list any place you departed from these constraints or from an
earlier frame, and why. A short "none" is fine.
````

### 12.3 Reviewing the returned frame

Before any stage 2b code, check the frame against this list. Any "no" is a Pause C item.

1. All seven panels (`t7-a`…`t7-g`) are present, or the owner said one can be skipped.
2. Every field draws at 16px or larger (invariant 18). No `maxlength`-style hard stop,
   and counters on address and category (invariant 11).
3. One tangerine action per screen; on `05`, the annotation says what the forward action
   is.
4. No rating, price, hours, distance or provider photo appears anywhere (D-052 §4,
   research trap I).
5. No phone, website or map link on the ballot (§1.7).
6. The share copy names *description*, visibly and in full (§3.2, Q6).
7. The OSM credit appears on OSM-derived items only, with the pre-split
   prefix/link wording (§1.7).
8. No map embed, no raw coordinates shown to organizers (§1.6).
9. `t7-d` keeps name and description read-only after publish (§1.4, invariant 16).
10. Anything the annotations list as a deviation is either accepted by the owner or
    taken out.
