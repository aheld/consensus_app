# Assisted Add — v1 UX brief

**Status:** product brief for design handoff (Claude Design). Not an implementation plan — that
comes after the design lands, in `docs/plans/`. Grounded in
[docs/research/activity-discovery.md](../research/activity-discovery.md) (the 2026-08-09 reviewed
version) and [docs/PRD.md](../PRD.md).

**Date:** 2026-08-11

---

## 1. The product call this brief encodes

v1 assumes **the organizer already knows the options they want the group to vote on**. Discovery —
browsing for candidates you haven't thought of — is a later release.

Between the two shapes on the table, v1 builds **neither**:

- **A full search & discovery interface** (the parked frame
  `docs/design/screens/1a-3-phase-2-discover-behind-restaurant.html`) answers *"what's good near
  Fishtown?"* — a question our v1 organizer isn't asking. Deferred.
- **"Simple autocomplete" is a trap: it is UX-simple but infrastructure-heavy.** Keystroke-level
  suggestions need a sub-100ms, always-on backend. The free stack we've committed to can't provide
  that: Nominatim's usage policy **forbids** implementing autocomplete against it outright, and
  Overpass measures 1.5–14s per query with roughly two request slots shared by *every* organizer on
  our single machine. Honest typeahead only becomes possible after the local Overture SQLite extract
  lands (research Stage 3, ~0.4ms local queries). Autocomplete is a *later* upgrade, not a simpler
  starting point.

The v1 shape that actually fits "the user knows the option" is **lookup, not discovery**:

> **Type the name you already know. The app finds the venue's link and dresses up the card.**

One lookup per added option, fired *after* the organizer presses Add — never per keystroke. It
degrades to exactly today's behavior, and it reuses the research doc's entire recommended
architecture (search returns URLs, the existing LinkPreview pipeline enriches).

## 2. The problem, concretely

On `02 add options` today:

- **Typed name → a bare card.** Striped placeholder, no photo, no description. A pool built by
  typing looks unfinished, and the rich-card experience (PRD §5.1.B, the Alex-the-Foodie relief) is
  gated on the organizer doing extra work.
- **Pasted URL → a rich card, but the organizer paid for it with a round trip.** Leave the app,
  search Google/Maps in another tab, find the venue's site, copy the link, come back, paste. The app
  outsources the lookup to the user's browser. On a product whose primary metric is Time to
  Consensus under 5 minutes, that round trip — times five options — is the single largest avoidable
  friction on the "I know what I want" path.
- The screen's own copy admits the gap: *"Restaurant search coming soon. For now, type the name
  yourself or paste a link."*

The paste path already proves the payoff end to end: `source_url` → LinkPreview → photo, title,
description. Assisted Add is nothing more than getting **typed names onto that same rail without
the round trip**.

## 3. v1 feature set

### F1 — Match-after-submit (the core)

Organizer types "Vernick" and presses **Add**. The card lands in the pool immediately, bare, exactly
as today — the lookup never blocks the add. In the background, one search runs against the free
places index. When it returns:

- **Match found:** a compact, dismissible suggestion appears attached to the new card — *"Is this
  it?"* with the venue name and street address, and a one-tap **Use this**. Tapping it sets the
  card's `source_url` and the existing LinkPreview enrichment runs exactly as if the organizer had
  pasted that link: photo, title, description fade in.
- **Nothing found / provider down / too slow:** nothing appears. Silence, not an error. The card is
  exactly what today produces, and the organizer never learns a lookup was attempted.

Dismissing a suggestion is a first-class outcome, not a failure — the typed name stands.

### F2 — The area prompt (one-time, stored on the group)

A name lookup needs somewhere to look ("Vernick" exists in many cities). The first time the assist
needs it, ask once — *"Where should we look?"* — a single typed neighborhood-or-city field,
submitted (never typeahead — policy), geocoded once, and stored **on the group, not the person**.
The research's privacy analysis holds: the pool already names local restaurants to everyone with
the link, so a neighborhood string is a property of the dinner, not the organizer. Editable
afterward; never a browser geolocation prompt.

### F3 — Paste-path upgrade (independent, ship whenever)

Teach LinkPreview to read `schema.org` JSON-LD (research Stage 2, ~half a day). Same paste, better
cards — and it quietly covers recipes, movies, books, and events with no vendor, key, or license.
No design work needed beyond what the current card already shows.

### F4 — Honest copy swap

When F1 ships, the *"Restaurant search coming soon"* line is replaced with copy that describes what
the assist actually does. The dashed `Bars` / `Movies` chips stay dashed.

### Engineering gates (sequencing truth, not design scope)

Research Stage 0 runs **before** implementation, and 0b can invalidate F1's payoff: measure whether
Fly's egress IP gets 403'd by venue sites (if LinkPreview can't enrich from production, "we find
the link" delivers bare names and we should stop). 0a — the invariant-12 source-grep test — lands
regardless. Neither affects the design.

## 4. UX specification for Claude Design

**Surface:** screen `02 add options`, inline. No new route, no new screen. The existing input +
yellow **Add** button are unchanged in position and behavior.

### The states

| State | What the organizer sees |
|---|---|
| Idle | The screen exactly as today. |
| Added, looking | New card in the pool immediately. A *quiet* activity cue (e.g. a shimmer in the card's striped photo frame). Must read as "nothing is wrong" if no suggestion ever follows. |
| One match | A compact suggestion attached to the card: venue name + street address (+ cuisine chip when present), **Use this**, and a dismiss ✕. |
| Two–three matches | Up to 3 rows of the same shape. The address line is the disambiguator — humans are excellent at spotting their own restaurant. Never more than 3. |
| No match / provider down / timeout | Nothing appears. No error state exists for this feature. |
| Confirmed | The suggestion collapses; the card enriches asynchronously exactly as a pasted link does today. |
| Dismissed | The suggestion collapses; the bare typed card stands. |
| Area unknown | The suggestion slot shows the one-time area prompt (F2) instead of results. After it's answered once, it never reappears; the pending lookup then runs. |

### Hard constraints the design must respect

1. **Nothing may imply search-as-you-type.** No dropdown under the input, no results that update
   while typing. Every lookup happens after Add is pressed. (Policy: Nominatim forbids
   autocomplete; infra: a shared, rate-limited volunteer endpoint.)
2. **Suggestion rows can show: name, street address, cuisine** (~80% coverage in measured data).
   **They cannot show: rating, price band, photo, open-hours, distance.** Every provider that has
   ratings forbids storing them, and the free data has no photos — this is the research §4.6
   finding that already forced a redraw of the parked Discover frame. Do not draw ★, $$$, or photo
   thumbnails on suggestion rows. The photo arrives *after* confirmation, via LinkPreview, on the
   card itself.
3. **Attribution is unconditional:** *"Places from OpenStreetMap contributors"* with an ODbL link
   must render wherever suggestions render. Small and quiet is fine; absent is not.
4. **Inputs:** any new field (the area prompt) computes at ≥16px (invariant 18) and carries no
   `maxlength` (invariant 11).
5. **One-handed portrait phone** is the target. The suggestion must not push the pool out of view
   or trap the organizer in a sub-flow — the input stays reachable for the next option while a
   suggestion is showing.
6. **Failure is silence.** No flash, no toast, no inline error for a failed lookup, ever.
7. Sticker design system throughout (`docs/design/DESIGN-SPEC.md`): ink borders, hard offset
   shadows, existing chip/card primitives.

### Copy direction

Replace the helper line under the input with something like: *"Type a name and we'll try to find
its link — or paste one yourself."* Tone per the design system. The word "search" should probably
not appear — this is not search, and calling it that invites the "thai near me" misuse the current
copy exists to prevent.

## 5. Explicitly out of scope for v1

- **The Discover screen.** The frame stays parked. When it's picked up (discovery release), its
  rating/price/distance elements must be redrawn per research §4.6 — that guidance transfers.
- **True autocomplete.** Revisit only after the local Overture extract (research Stage 3) makes
  sub-100ms lookups honest. Same UI surface could then upgrade.
- **Friends adding options (co-creation).** PRD-mandated eventually, deliberately absent today.
  The assist pattern designed here should port to it unchanged when that lands.
- **Multi-add** (paste "Zahav, Vernick, Suraya" → three cards). Cheap and on-thesis; fast-follow,
  not v1 — it complicates the input's parsing story (URL vs. list vs. name) and the assist's
  one-card-one-suggestion model.
- **De-duplication / "Added ✓"**, `provider`/`provider_ref` columns, distance labels.
- **New activity types.** Chips stay dashed; the provider registry keeps the engine type-agnostic
  (invariant 12) without any UI change.

## 6. Open decision points

- **D1 — Where the area prompt lives.** Recommended: in context, in the suggestion slot, the first
  time it's needed (the question appears at the exact moment its answer has visible value).
  Alternative: an optional "Neighborhood or city" field on `01 setup`. Claude Design should weigh
  both; the in-context version is the stronger default because `01` is currently two fields and
  fast, and we shouldn't tax every organizer for a feature only typed-name adds use.
- **D2 — v1 backend.** Overpass first (research Stage 1 rationale: the seam is the risky part, the
  source is the swappable part). Note the assist UX is *more* tolerant of Overpass's flakiness than
  a dedicated search screen would be — a missed suggestion is invisible, a failed search screen
  looks broken. This strengthens the case for the inline surface. The local Overture extract
  remains the destination.
- **D3 — Does confirming a suggestion overwrite a typed name?** Recommended: yes, the card takes
  the provider's canonical name (that's most of the polish), with the organizer's existing edit
  affordance on `02b` as the undo.

## 7. Relationship to the research doc

This brief **changes one thing** in the research's Stage 1: the UI surface. The research proposed a
new `Discover` LiveView behind the `Restaurant ›` chevron; this brief replaces that with the inline
assist on `02`, and defers the Discover screen to the discovery release. Everything else — the
`Consensus.Discovery` context, the `Provider` behaviour, the config registry, the URL-only
`Result`, the license rejections, Stage 0 gating, the SSRF rule for provider-returned URLs — is
adopted unchanged. When this scope call is ratified, it gets a `D-05N` entry in `decisions.md`
recording: lookup-not-discovery for v1, the inline surface, and the by-terms-not-price rejection of
commercial place APIs (so nobody re-litigates Google/Yelp in six months). The decisions log is past
D-050 now; the research doc's references to "a D-050 entry" predate that.

## 8. Success measures

- **Enrichment rate:** % of non-pasted pool options that end up with a `source_url` (i.e., the
  assist fired and was accepted). This is the feature's adoption number.
- **Acceptance rate:** suggestions accepted ÷ suggestions shown. Low acceptance with high volume
  means bad matches — tune or kill.
- **Silence rate:** lookups fired that showed nothing (no match, provider down, timeout). This is
  the feature's health number, and the trigger for accelerating the Overture extract.
- **Time on `02`** for pools with ≥3 options, before vs. after — the contribution to the primary
  Time-to-Consensus < 5 min metric.
