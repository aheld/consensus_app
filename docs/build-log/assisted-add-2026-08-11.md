# Assisted Add (D-052) — build log, 2026-08-11

Point-in-time record of the five-iteration build loop behind the Assisted Add, distilled
from the loop's own per-iteration notes. **Not authoritative and not maintained** — where
this contradicts `docs/decisions.md`, `CLAUDE.md` or the code, this file is the stale one.
It exists so that "why does the assist look like this, and what was rejected along the way"
has an answer later.

Shipped in commit `f0a5cfc`. The loop's working directory (`loop/`, 106 per-iteration
screenshots and one-off seed/probe scripts, ~14MB) was deliberately left untracked and is
gitignored; its conclusions are here instead.

## Stage 0 — the two gates that had to pass before any discovery code

Both were run first, on purpose, because either one failing would have killed the feature
rather than reshaped it.

**0a — the invariant-12 source pin.** `test/consensus/activity_type_invariant_test.exs`
(3 tests) landed *before* a line of discovery code, and was mutation-verified: a
`case group.activity_type do` introduced anywhere in `lib/` fails CI. Writing the pin first
is what made "the registry is data, never a branch" a checkable claim rather than an
intention.

**0b — the Fly egress measurement.** The whole enrichment thesis depends on venue sites
answering a request from a datacentre IP, which is exactly what bot walls block. Measured
from production, 6/6 clean:

| Site | From Fly |
|---|---|
| zahav | 297ms |
| vernick | 157ms |
| beddia | 119ms |
| vetri | 339ms |
| kalaya | 143ms |
| sweetgreen | 251ms |

Yelp returned 403 from Fly **and from residential** — a bot wall, not an egress penalty, so
it does not count against the thesis. `surayaphilly.com` fails locally too and was excluded
as unrelated. Net penalty for running from Fly: **0%**. Green light.

## What got built, in order

Backend seam first (area migration → discovery core → Overpass adapter), each stage taking
a fresh critic before the next started, run sequentially because there is one SQLite file
and one `_build`. Then the UI on frame `02`, then the state-table tests, then docs.

The Overpass stage passed only after a fix round, and the two things the critics caught are
worth keeping:

- **An IPv4-mapped-IPv6 SSRF bypass** in the host check. Fixed and re-verified. This is the
  reason provider URLs go through `LinkPreview.check_host/1` — the same allowlist as the
  paste path, never a second one that can drift out of agreement with it.
- **Overpass QL injection.** Queries are escaped; proofed by test.

## Decisions taken in the loop

Recorded properly in D-052; listed here with the reasoning that produced them.

- **Registry shape.** Production config registers four activity types against the *same*
  Overpass module with different tag lists; test config swaps in a stub registry so the live
  adapter is never reached from the suite. Four types, one module, is what leaves nothing
  type-shaped to branch on.
- **The `02` chips stay dashed.** The brief's F4 beat the research doc's suggestion of
  deriving the chip row from `available_types/0`. Bars/Movies remain inert, Post-MVP.
- **`Result.address`** is a deliberate extension of research §4.3, added for the brief's
  suggestion-row spec. Display-only; it does not widen what is retained.
- **Area storage** is `search_area` (the typed string) plus `search_bbox`
  (`"min_lat,min_lon,max_lat,max_lon"`) on the *group*, with a draft-gated setter and
  head-match ownership.
- **In-slot area prompt only** (frame `02f`). The `5b` variant on frame `01` was not built.
- **Confirming a suggestion overwrites the typed name** with the provider's canonical one;
  the `02b` edit is the undo; cross-fade between them.
- **Violet accent family for the assist**: slot `#F5F1FF`, shimmer `#D6CCFB`/`#F1ECFE`,
  enrichment shadow `#6B46F0`.

## Blind A/B against the design renders

Two rounds at phone width, screenshots driven by a dev-only scripted provider
(`dev/support/scripted_provider.ex`, with `ASSIST_LIVE=1` flipping to real Overpass).

- **Round 1 — 6/6 matched, 4 of them "certain".** Real tells, all fixed: shimmer opacity,
  slot row layout, area shadow violet, Edit-pill white-at-rest, "N yours" wording, a stray
  caption. This round also surfaced a genuine bug: **`og:title` was overwriting the
  just-confirmed canonical name.** Fixed, with 4 probe tests pinning it.
- **Round 2 — 6/6 matched, ZERO "certain"** (all "likely"). The remaining tells were
  dominated by mockup staging rather than by our output: fade-mask crops, the ALEX and
  "from friends" garnish, fixed-height comps. Genuine ones fixed in the final round: H1
  wrapping to two lines, disabled chips too loud, the "Name or link" placeholder, and the
  input scroll model (the frame puts the pool under a fixed input; we had page scroll —
  resolved with the sticky add-form dock).

**Deliberately not changed**, each recorded rather than quietly dropped:

- The suggestion slot is attached to the card, not placed under the input — the brief wins
  over the drawing.
- The area prompt keeps its dismiss `X` — an annotation over the drawing.
- The in-content back circle is D-041's global chrome, not a deviation.
- The "needs-details nudge" (gray title + yellow pill) was **skipped**: two blind readings
  disagreed about what the frame was even depicting, so it was judged ambiguous storytelling
  rather than spec.

Judged diminishing returns after round 2 and stopped.

## Real-backend drive

One full flow against live Nominatim and live Overpass, zero deviations from the scripted
path. Measured:

| Step | Time |
|---|---|
| Geocode (Nominatim) | 1.34s |
| Search (Overpass) | 0.69s |
| Enrichment | ~0.5s |
| Silence path | 3.1s shimmer, then nothing |

That last row is the one that matters most: every failure mode renders as silence, and 3.1s
is how long the organizer sees a shimmer before the card settles into exactly what today's
typed path produces.

## Leftovers — all deliberate, none blocking

- **F3 (LinkPreview JSON-LD, research Stage 2) was not built.** The brief calls it
  independent of the assist; it is a fast-follow, not a gap in what shipped.
- `visibleTop()` does not fold in a visible sticky flash — transient occlusion, and a
  pre-existing pattern rather than something the assist introduced.
- The dock's `top-[48px]` duplicates the header-height constant. Documented coupling; the
  hook measures live, so the two cannot silently disagree at runtime.
- Dev database residue from the real-backend checks: draft groups 142, 145, 146, 147 under
  `aheld`. Local only.

## Process notes worth keeping

- **`DesignSync` is session-bound** — subagents cannot call it. The orchestrator has to
  fetch the design files itself and hand them over. This blocked iteration 2 until it was
  understood.
- **`get_file` truncates at 256KiB.** Frame `t5` came through complete; the `t1` tail had to
  be recovered from the repo's own Aug-8 copy of `docs/design/create-and-share.dc.html`.

## Final gate

`mix precommit`: **1171 tests, 0 failures** (was 1034 before this feature).
