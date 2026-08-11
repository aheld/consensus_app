# Endgame screens: All Vetoed & Tie

Two designed completion screens replacing the muted one-liners on both results pages, from
the Claude Design project (867b0685-278c-4ce4-ae2c-bce2135705af):

| Source | Committed as | Ground truth render |
|---|---|---|
| `Consensus - All Vetoed.dc.html` | [docs/design/all-vetoed.dc.html](../design/all-vetoed.dc.html) | serve `docs/design` and open `/all-vetoed.dc.html` |
| `Consensus - Tie.dc.html` | [docs/design/tie.dc.html](../design/tie.dc.html) | `/tie.dc.html` |

Both docs use the dc runtime (`support.js`, already committed beside them) — templating,
`sc-for`, `DCLogic` state — so **render them via HTTP, not by reading alone**:
`python3 -m http.server 4999 --directory docs/design`, then screenshot with headless
Chrome. Verified working 2026-08-10. The scenes animate; the poke/spin logic runs.

Relevant settled decisions this plan must not contradict: D-034 (veto elimination, no
fallback to least-vetoed), D-035 (anonymity is structural — totals only), D-036 (a cast
ballot is locked), D-037 (the pool freezes when the vote opens), engineering invariants
16/17, product invariants 3/5/6.

## What the designs settle (their own annotations, verbatim intent)

- **Tie**: "Replaces the plain 'it ended in a tie' note on the results page. Only the
  organizer sees the two exits — tap a tied option to choose it outright, or hand it to
  the app, which shuffles the tied set and lands on one; either way the result writes back
  to /groups/:id/results, so the final tally below stays where everyone already has the
  link. Guests see the same scene with a waiting state instead of the buttons."
- **All Vetoed**: "Triggers when every option in a session has been vetoed. Tapping the
  guy escalates the headline through four stages, then resets — nothing here blocks the
  two real exits."
- The same guest rule is applied to All Vetoed by symmetry: guests get the scene, the
  carnage list, and a waiting line — never the exits (only the organizer can add options
  or trigger the pick; both are writes on the organizer's group).
- Both screens are **states of the existing results LiveViews**, not new routes. They
  render only when `group.status == :completed` and the endgame is unresolved.

## The shared structure (build it once)

Header context slot (`ALL VETOED` in tangerine / `DEAD HEAT` in violet — the slot gains
an optional accent, today it is always muted), then a body that replaces the whole
results panel: 250px hero card (ink border, radius 18, `shadow-sticker-4`, dark themed
background, animated SVG scene, yellow buzzing counter chip top-left, quiet outlined
label chip top-right), headline block (700 30px / 400 14px), a list card (ink border,
radius 14, mono header band, rows), an action stack (primary shadowed button, plain
secondary, mono caption line), the global footer as on every screen. No avatar row, no
tally bars, no violet countdown band while the takeover shows.

Suggested shape: `ConsensusWeb.EndgameComponents` for the shared chrome + two
**LiveComponents** (`ConsensusWeb.Endgame.AllVetoed`, `ConsensusWeb.Endgame.Tie`) so each
screen owns its events (`poke`, `select`, `app_pick`, `lock`, `rescue`) and the two
results LiveViews only grow one branch each. Both LiveComponents take `role:
:organizer | :guest` and (organizer only) the `%Scope{}` for writes. The builder may
deviate if a cleaner shape appears — the file-level separation (each screen's logic in
its own module) is the part to keep, so the two screens can be iterated independently.

## Data model: resolution is recorded, never destroyed into

One migration on `activity_groups`:

- `resolution` — string, null. Values: `"organizer_pick"` (tie: organizer tapped a row and
  locked it), `"app_pick"` (tie: the app shuffled), `"app_rescue"` (all-vetoed: the app
  picked one at random and its veto is undone).
- `resolved_activity_id` — references `activities`, `on_delete: :nilify_all`.
- `resolved_at` — utc_datetime.

**No vote rows are deleted by resolution.** "Undo that option's veto" is a presentation
and outcome rule, not a data mutation: `Voting.tally/1` treats the resolved activity of an
`"app_rescue"` as un-vetoed (`vetoed?: false`, plus a new `rescued?: true` key on every
row, false elsewhere) and ranks it among survivors; `winner?`/`leader?` go to
`resolved_activity_id` whenever it is set and the group is `:completed`. The votes stay
true; only the interpretation is recorded. This is the same shape as
`presentable_tally/2` — but it lives in `tally/1` because it changes the *outcome*, not
just the paint.

## Context functions

In `Consensus.Activities` (organizer writes on the group — scope-first, organizer-matched
in the function head, same as every other group write):

- `resolve_group(scope, group, activity_id, resolution)` — refuses unless status is
  `:completed`, no resolution already recorded, the activity belongs to the group, and
  the activity is in the valid candidate set (tie: the tied-at-top survivors; rescue: the
  vetoed pool). Stamps all three columns, broadcasts `{:group_updated, group}` so every
  open results screen flips at once. Returns `{:ok, group}` or a tagged error. Rescue
  candidate choice (`:rand.uniform/1`) happens in the **caller-facing helper**
  `rescue_group(scope, group)` which picks the random vetoed activity server-side and
  delegates — so tests can call `resolve_group/4` deterministically.
- `reopen_group(scope, group)` — the "Add new options" exit. Refuses unless `:completed`
  with **every option vetoed** and no resolution. Then, in one transaction: status back
  to `:draft`, `completed_at` and the resolution columns cleared, **`deadline_at`
  cleared** (the old deadline has passed; leaving it set would let round 2 re-complete
  itself on the first read after publish — `maybe_complete_group/1` fires on every read),
  every vote row in the group deleted, every participant's `voted_at` reset to nil
  (participants and their tokens survive — the share link keeps working and nobody
  re-enters a name). Broadcasts. The organizer lands on `/groups/:id/options` with a
  flash saying the pool is open again and a new deadline is needed before publishing
  (deadline is set on `/groups/:id/edit`; `publish_group/2` already refuses
  `:no_deadline`). Round 1's votes are gone by design — its outcome was "everything
  vetoed", and the screen the organizer is leaving said exactly that.

`Voting.outcome/2` (group, tally) supersedes `outcome/1` at both call sites: adds
`{:tie, tied_rows}` for a `:completed`, unresolved dead heat (two-plus survivors sharing
the top nonzero approval count); keeps `:no_consensus` as the all-vetoed answer
(unresolved); returns `{:winner, row}` once resolved (the flags in `tally/1` already
point at the resolved activity). `outcome/1` stays for compatibility, documented as
status-blind.

The **existing tie presentation** in `ResultsComponents` (the "Tied at the top" winner
card variant, `tie_note/2`, the tie flavor of `winner_summary/3`, `finished_headline/2`'s
tie branch) becomes the **resolved** rendering: after a tiebreak the winner card and the
paste-to-chat string say the tie was broken and by whom ("picked by <organizer>" /
"picked by the app") rather than "takes it because it was first in the pool" — position
no longer settles anything a human or the app has settled. The unresolved-tie rendering
is the takeover.

## Per-screen specifics

### All Vetoed (`:no_consensus`, completed, unresolved)

- Hero: the fire scene, transcribed from the design SVG exactly (flames, embers, the
  bobbing guy with waving arms). Counter chip `VETOES N/N` where N = pool size **plus one
  per poke** (the design increments it comically; `(6+p)/(6+p)` in the source). Label
  chip `TAP THE GUY`.
- Poke: tapping the hero cycles headline/subline through the four stages verbatim from
  the design source (stage 0 "Nobody wanted anything." … stage 3 "Total anarchy
  achieved."), then wraps to 0. Client-visible state only; guests get it too.
- THE CARNAGE list: every option, strikethrough, tangerine ✕ badge. **Right-hand mono
  slot shows the veto count (`1 VETO`, `2 VETOES`) — never a name.** The design's sample
  data (`MAYA`, `DEV`) attributes vetoes to people, which D-035 makes structurally
  impossible; this deviation is deliberate and gets recorded in the D-entry and in
  DESIGN-SPEC/IMPORT-NOTES wording. Same slot, same type, honest data.
- Actions (organizer): primary tangerine **ink-text** button `Add new options` (the
  design uses ink on tangerine here, unlike the app's usual white-on-tangerine — follow
  the design) → `reopen_group/2`; secondary `Let the app pick one at random` →
  `rescue_group/2`, which flips every open screen to the normal winner ending (the
  rescued row un-struck, the winner card naming it, with an honest line that the app
  picked it after a full veto). Caption: `or accept that pizza was always the answer`.
- Guests: scene + headline + carnage, a waiting line naming the organizer as the one who
  can fix it, and the existing `Create your own →` exit. No organizer exits.

### Tie (`{:tie, rows}`, completed, unresolved)

- Hero: the tug-of-war scene (violet radial night, two straining figures, yellow knot,
  pulsing center line). Counter chip `TIED N-WAY` (buzz), label chip `NOBODY'S WINNING`.
- Headline `It's a dead heat.`; subline varies by state exactly as the design's logic:
  nothing selected → "Voting is closed and two options finished on the same score. Only
  you can break it." / selected by tap → "Locking it in updates the results page for
  everyone who voted." / app picked → "The app broke the tie. Lock it in, or override
  it — you're the organizer."
- List card `TIED FOR FIRST` + state chip (`TAP ONE` / `DECIDING…` / `APP PICKED`);
  rows: 20px dot (violet ✓ when active — the doc's 20px is content-box, so it *renders*
  24px with its 2px border; the app's border-box class is `size-6`, IMPORT-NOTES §11),
  name, `N VOTE(S)` in violet mono; status line
  beneath (`Nothing selected yet` / `Shuffling the tied options…` / `Selected: <name>`).
  Row selection is provisional UI state; nothing writes until Lock.
- Primary: disabled-looking `Pick a winner above` (`#EDE6DC`, ink text) until a selection
  exists, then `Lock in <name>` on tangerine → `resolve_group/4` with `"organizer_pick"`
  or `"app_pick"` depending on how the selection was made. Secondary: `Let the app break
  the tie` → a ~1.9s shuffle animation cycling the row highlight, landing on a
  server-chosen (`:rand`) tied row, still provisional until locked. Caption: `or run a
  second round with just these two` (inert mono line, as drawn — it suggests, the D-entry
  notes why it doesn't press). Below it the page's own URL in faint mono.
- Guests: same scene and list (no tap targets, no ✓ affordance), waiting copy naming the
  organizer, `Create your own →` exit.

## What the critics drive (the acceptance script)

1. Seed an all-vetoed completed group and a 2-way-tie completed group (see
   `scratchpad/seed_states.exs`; extend for 3-way if useful).
2. Screenshot ours (organizer view, logged in via the cookie helper; guest view
   cookie-less) beside the design renders at matching viewport; blind A/B — hand the pair
   unlabeled to a fresh-context judge who must say which is the design and name the
   single biggest gap. Live data vs sample data (names, counts, URL host) is a known,
   excusable delta; craft (type, spacing, borders, shadows, color, scene geometry,
   animation presence) is not.
3. Exercise every behavior: poke ×5 (stages cycle and wrap), app-rescue flips both an
   organizer tab and a guest tab to the normal winner ending live (PubSub, no reload),
   the rescued row renders un-struck with honest copy; add-options reopens →
   options screen unlocked → new deadline via edit → publish → a guest votes again on
   the same link → normal ending; tie: tap-select → lock, app-spin → lock, override after
   app pick; guest waiting states; every refusal path returns a tuple (double-resolve,
   resolve on someone else's group, resolve while `:voting`, reopen a non-all-vetoed
   group).
4. `mix precommit` clean; the ten `footer_state` cells and chrome route tests still hold
   (takeover states bypass the footer table — they carry their own exits — but every
   non-takeover cell must render exactly as before).

## Open notes for the D-entry

- Takeovers render for `:completed` only; a mid-vote all-vetoed pool still shows the
  ordinary running tally (people can still approve; the state can still gain vetoes).
- `:vetoes_only` (some options vetoed, no survivor approved) is **not** a takeover and
  keeps its current card — the design covers the all-vetoed case only.
- The tie takeover renders for unresolved ties regardless of how the group completed
  (deadline or Close now).
- Stage-2 poke copy says "restaurants" (design verbatim) — screen copy in the web layer,
  not a branch on `activity_type`; invariant 12 untouched. Note it anyway.
