# Design prompt — Assisted Add (v1)

Paste everything below the line into a Claude Design session. It is self-contained: Claude Design
has no access to this repo, so the brief's constraints are embedded rather than referenced. The
product brief it encodes is [docs/design/assisted-add-ux-brief.md](../design/assisted-add-ux-brief.md).

---

Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Create+%26+Share.dc.html

You are designing **Assisted Add**, a v1 feature for Consensus — the group-decision app in the
imported project. Work inside the existing file, in the established sticker visual system (ink
borders, hard offset shadows, chips, striped photo placeholders). Do not restyle anything that
exists; you are adding states to one screen.

## What the feature is

On the **02 Add Options** screen (existing frame: `02 add options — manual MVP`), the organizer
types a restaurant name and presses **Add**. Today that produces a bare card — striped photo
placeholder, no description — unless they leave the app, find the venue's website, and paste the
link instead.

Assisted Add closes that gap with **lookup, not search**: after Add is pressed, the card lands in
the pool immediately (bare, exactly as today), and the app quietly looks the name up in the
background. If it finds the venue, a small dismissible suggestion appears attached to the new
card — *"Is this it?"* with the venue's name and street address and a one-tap **Use this**.
Confirming attaches the venue's website link to the card, and the card then enriches itself with a
photo and description exactly the way a pasted link already does in the existing designs.

What this feature is **not** — and the design must not imply otherwise:

- **Not autocomplete.** Nothing happens while typing. No dropdown under the input, no results that
  update per keystroke, no affordance that suggests live search. Every lookup fires only after Add
  is pressed. (The backend policy and infrastructure make typeahead impossible; a design that
  implies it would be a lie.)
- **Not the Discover screen.** The existing `phase 2 — discover behind restaurant` frame stays
  parked and untouched. This feature never shows a browsable result list, categories, or a search
  box of its own.
- **Not a gate.** The add always succeeds instantly. The suggestion is a bonus that arrives late or
  never; the organizer can keep adding the next option while it's pending.

## The states to design

Design each of these as its own frame, mobile portrait, matching the existing frame conventions:

1. **Baseline, revised copy.** The 02 screen as it exists, with the helper line under the input
   replaced. Current line: "Restaurant search coming soon. For now, type the name yourself or paste
   a link." New direction: *"Type a name and we'll try to find its link — or paste one yourself."*
   Refine the copy; avoid the word "search."
2. **Added, looking.** A new bare card just landed in the pool. A quiet activity cue plays on it —
   suggestion: a shimmer inside the card's striped photo frame. Constraint: if no suggestion ever
   arrives, this state must simply settle back to the plain card without ever having looked like an
   error or a promise.
3. **One match.** A compact suggestion attached beneath the new card: *"Is this it?"* + one row
   with the venue name and street address, a **Use this** action, and a dismiss ✕. Dismissing is a
   normal outcome, not a failure — the typed card stands.
4. **Two–three matches.** Same shape, up to three rows. The street address is the disambiguator —
   the organizer is picking *their* Vernick out of a short list. Never more than three rows, no
   "see more."
5. **Confirmed.** The suggestion collapses; the card shows the venue's canonical name and is
   enriching (photo/description arriving), consistent with how an enriched card already looks in
   the existing frames.
6. **Area prompt.** The first lookup needs to know roughly where to look. The first time only, the
   suggestion slot shows a one-time question instead of results — *"Where should we look?"* — one
   typed neighborhood-or-city field with a submit. Answered once, stored on the group, never asked
   again. Design this in-context (in the suggestion slot). **Also produce one alternative frame**
   placing it as an optional field on the 01 Setup screen instead, so the placement can be chosen —
   label the two variants clearly.

There is deliberately **no failure state to design.** No match, provider down, too slow — all of
them render as nothing at all. No toast, no flash, no inline error. Do not design one.

## Hard constraints (these are load-bearing, not preferences)

- **Suggestion rows may show exactly: venue name, street address, and optionally a cuisine chip.**
  They may NOT show ratings, price bands ($$$), photos, thumbnails, distance, or open-hours. This
  is a licensing constraint, not a data gap we'll fill later: every provider that has ratings
  forbids storing them, and the free data behind this feature has no photos. The photo arrives
  *after* confirmation, on the card, from the venue's own site. If a suggestion row looks sparse,
  make sparse look intentional — do not decorate it with placeholder stars or price glyphs.
- **Attribution is unconditional.** *"Places from OpenStreetMap contributors"* (linking to ODbL)
  must appear wherever suggestion rows appear. Small and quiet is fine; absent is not. Find it a
  home that doesn't fight the layout.
- **Any focusable text field in these frames is specified at 16px, not smaller.** Earlier frames in
  this project spec'd 13–15px fields and the build had to deviate upward on every one: iOS Safari
  zooms the page when a focused field computes under 16px and never zooms back out. Spec 16px so
  the frames and the build finally agree; adjust padding, not type size, if a box height needs to
  match.
- **No `maxlength` semantics.** Don't annotate character limits on the area field or imply
  truncation behavior.
- **One-handed portrait phone.** The input and Add button stay reachable while a suggestion is
  showing, and the pool must not be pushed out of view. A suggestion is an interruption of one
  card's row, never of the screen.
- The activity-type chip row (Restaurant selected; Bars/Movies dashed and inert) is unchanged.

## Deliverables

- The frames above, in the imported project file, named consistently with the existing
  `02 add options` series.
- Final microcopy for: the helper line, the "Is this it?" prompt, **Use this**, the dismiss, the
  area prompt question and its placeholder, and the attribution line.
- One short note per frame on motion/behavior (what animates on suggestion arrival, collapse on
  confirm/dismiss) — enough for an engineer to build without guessing.
- Your recommendation between the two area-prompt placements, in one or two sentences.
