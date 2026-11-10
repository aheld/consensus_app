# Plan — more of each option's description, on the ballot and in the creation flow

GitHub issue: aheld/consensus_app#7 — *"In grid view, only a few words are visible of the
restaurant description. Update the design so that more of the description is visible, mainly
in the voting screens, but also in the creation views."*

Status: **Part A done, 2026-11-10. Part B built, 2026-11-10 — recorded as D-062.** The `t8`
frame came back, was reviewed (§A.4), and the owner ruled on all nine conflicts (§A.5).
DESIGN-SPEC has its `t8` section (§A.6). Part B stages 0–4 are in the code and the §3 tests
pass; §4's in-browser checks at 375×812 / 360×640 have **not** been run yet. Where Part B below and §A.5 disagree, §A.5 wins; the Part B text has been
edited to match it.

Decisions this plan touches: D-028 (design tokens), D-036 (the locked ballot), D-044 (grid +
deck are two views of one selection), D-046 (16px fields), D-057 (the design site, getting a
frame back), **D-060 `t7-e` / `t7-f`** (which this plan amends), and CLAUDE.md invariants 11
and 18 and product invariant 1.

## 1. Why

PRD product invariant 1 makes the guest ballot the whole product for most people, and the
description is the only free text that tells a guest *what* an option is. Today it is nearly
invisible:

| Surface | What a description gets today | Where |
|---|---|---|
| Ballot grid tile (`1c-1`) | one `truncate` line, DM Mono 10.5px, in a half-width tile — **and none at all once the option has an address**, because `tile_meta_line/1` gives the address that slot (D-060 `t7-f`) | `JoinLive.Ballot.grid_view/1`, `tile_meta_line/1` |
| Swipe deck card | `line-clamp-2`, 12px | `Sticker.deck_stack/1` (`detail` attr), fed by `meta_line/1` |
| `02` add-options card | **never** — the provenance line, or chip + address (`t7-e`) | `GroupLive.Options`, the streamed pool card |
| `03` review row | one `truncate` line, 11px, **hidden whenever the option has a category or address** | `GroupLive.Review` |
| Results (`05`, `/join/:slug/results`) | full text, unclamped | `ResultsComponents` — out of scope |

So every option added through Assisted Add's **Use this** (which fills an address) has no
description on the grid, `02` or `03`. That's the main bug. The truncation makes it worse.

`Activity.max_description_length/0` is 140 graphemes, so the full text is always short enough
to show somewhere. It just doesn't fit in a half-width tile at a readable size (≈6–7 lines).

## 2. What the owner decided (2026-11-09)

1. **Grid tile shows both.** Chip on the photo (unchanged), address on its one line, then the
   description as its own clamped block below it. The address no longer *replaces* the
   description. That reverses the `tile_meta_line/1` half of `t7-f`.
2. **Clamp plus "more".** The grid tile clamps the description to ~3–4 lines (the frame picks
   the exact number). A separate **more** control (ⓘ or a word, as the frame draws it) opens
   the full text. Tapping the tile still means *approve*, so the control can't be the tile.
3. **The more sheet is read-only option info.** Photo, name, chip, address, the full
   description, and the website (`source_url`) as a new-tab link. Close returns to the ballot
   untouched. **No vote controls in the sheet.** It never changes `@approved`/`@veto_id`, so the
   two views (D-044) don't get a third source of truth.
4. **Deck card: higher clamp plus the same "more".** `line-clamp-2` goes to ~4, and the same
   control opens the same sheet. One mechanism in both views.
5. **Creation views: both `02` and `03`.** Each card or row shows a clamped description (~2
   lines) *under* the chip + address / provenance line instead of being replaced by it, so the
   organizer sees what guests will see.
6. **Design goes through Claude Design** as turn `t8`, the same protocol as `t5` and `t7`
   (`docs/plans/item-details-and-catalog.md` §12).

Out of scope: results screens (already full text), `/admin/items`, the share sheet and the
`og:` unfurl (D-050's 200-character clamp is separate and correct), and any change to the
140-grapheme cap.

---

# Part A — Design (no code)

The design source of truth is the linked Claude Design project (D-057). Only the owner can run
a prompt there, so Part A is a handoff with two stop points.

### A.1 Stop points

| # | When | What the session does | What resumes it |
|---|---|---|---|
| **A** | Start of the build | Prints §A.2 in a fenced block, ready to paste, and ends the turn. | The owner says the frame is ready. Part B's stage 0 can run meanwhile. |
| **B** | Frame review (§A.4) finds a conflict | Lists each conflict, the decision or invariant it breaks, and a recommended resolution, then ends the turn. Never picks silently. | The owner rules on each one. Rulings are written into §A.5. |
| **C** | During Part B, a state the frame doesn't draw | If it's a direct combination of drawn parts, build it and list it in the stage summary. If it needs new vocabulary or copy, stop and ask, offering a follow-up prompt. | The owner's answer. |

### A.2 The prompt

Paste into the linked project's **Consensus · Create & Share** file as a new turn:

````text
New turn: t8 · Longer descriptions. Same file, same phone frame (375 wide), same sticker
system as t1–t7. Draw new panels only. Do not restyle anything else.

## The problem

Each option has a short description (at most 140 characters, typed by the organizer or
pulled from a pasted link). Guests can barely read it:
- On the sticker-grid ballot (1c-1) it's one truncated mono line in a half-width tile, and
  since t7 it disappears completely when the option has a street address, because the
  address took that line.
- On the swipe-deck card it's clamped to 2 lines.
- On 02 add options and 03 review the address/provenance line replaces it.

The description is how a guest knows what they're voting for. Make more of it visible,
mainly on the ballot, but also on 02 and 03.

## Decisions already made (draw these, don't revisit them)

1. A grid tile shows BOTH: category chip on the photo strip (as t7-f), the street address on
   one truncating line, then the description as its own block, clamped to 3 or 4 lines (pick
   whichever keeps a 2-column grid readable at 375 wide; say which).
2. Tapping a tile still means "pick it". So the full text sits behind a separate, small
   "more" control on each tile. It must not sit inside or overlap the tile's tap area or the
   VETO bar under it (we removed an overlapping veto for exactly that reason), and it must
   be at least 44×44 including any invisible padding. A good candidate is sharing the row
   with the VETO bar, but you choose.
3. "More" opens a read-only sheet: photo, name, category chip, address, the FULL
   description, and a "Website ↗" link when there is one. One way to close it. No
   pick/veto buttons in the sheet.
4. The swipe-deck card clamps the description to ~4 lines (up from 2) and carries the same
   "more" control, which opens the same sheet. The card is draggable, so the control must
   read as a button and not as part of the card.
5. 02 add-options cards and 03 review rows: keep the chip + address line (or the provenance
   line when there are no details), and add the description UNDER it, clamped to 2 lines,
   in muted body type. No "more" here: the organizer can open 02b to read or edit it.

## Constraints
- Text in tiles can't go below what's readable on a phone; no description smaller than the
  t7 address line. Mono stays for the address only; the description is body type (Inter).
- Grid rows stay even: two tiles in a row should have the same height and their VETO bars
  should line up, even when one has no description, a 1-line one or a 140-character one.
- Ellipsis, never a silently clipped line.
- Show what a tile looks like with no description at all (it shouldn't get an empty gap).

## Panels to draw (label them t8-a … t8-f)

t8-a · 1c-1 sticker grid, 6 options: one with photo + chip + address + a 140-character
       description; one with a description but no address; one with an address but no
       description; one with neither; one PICKED; one VETOED (show how the description
       dims with the struck-through name).
t8-b · The same grid with the "more" control's pressed/focus state on one tile.
t8-c · The read-only "more" sheet over the grid, for the 140-character option with every
       detail; and a crop of it for an option with only a name and a description.
t8-d · One swipe-deck card with a 4-line clamped description and the "more" control; and
       a crop of the same card mid-drag showing the control stays legible.
t8-e · 02 add options: three cards (assisted add with address + description; typed with a
       description only; typed with nothing). Include one card in the 02e "details
       arriving" state so the description slot's behaviour there is drawn.
t8-f · 03 review: the same three options as rows, before publish (drag handle, ×) and after
       publish (Fix details link).

For each panel, note the font size, weight, line-height and clamp of the description.
````

### A.3 Getting the frame back

Read it with `DesignSync` `get_file` and **check `truncated`**. Create & Share is over the
256 KiB cut-off (D-057 §3). If it's cut, ask the owner to export it. Save it under
`docs/design/site/` with the `data-omelette-injected` preview harness stripped (D-057 §2), and
add it to `docs/design/site/index.html`.

### A.4 Frame review checklist

Before any template code, check the frame against:

- **Overlapping targets.** The more control and the approve button must have disjoint rects.
  It's also invalid HTML for a `<button>` to sit inside the approve `<button>`, so it has to be
  a sibling (the VETO bar's shape).
- **≥44px** for the more control and the sheet's close control.
- **Even rows.** Check that the frame actually reserves the clamp's height or otherwise keeps
  the VETO bars aligned (the 60px misalignment `ballot.ex` documents).
- **Viewport floor.** The grid's `min-h-[200px]` and `.viewport-column`'s 640px gate still
  leave at least one full row of taller tiles visible at 360×640. *(Amended by §A.5 ruling 2:
  at 360×640 the first row's tile text must be visible, and its VETO/More row may need a
  short scroll inside the track.)*
- **Tangerine.** Still reserved for "Send my votes". The more control and the sheet's website
  link can't be tangerine.
- **The sheet's website link opens a new tab** (`t7` ruling 4: any same-tab link off the
  ballot discards the unsent ballot).
- **No field changes.** Nothing here is an input, so invariants 11 and 18 shouldn't come up.
  If the frame adds a field, flag it.
- **Copy.** Whatever the control says ("More", "ⓘ", "Read more") needs an `aria-label` that
  names the option (`More about <name>`), the way `deck_veto_label/4` does.

### A.5 Owner rulings on the frame

**Frame:** `docs/design/site/longer-descriptions.dc.html` (`T8-Descriptions.dc.html` in the
design project, imported by Create & Share). Read 2026-11-10 from the migrated project's
artifact copy, not truncated (71,697 bytes). The live `DesignSync` listing didn't show the
file and returned Create & Share cut at 256 KiB. Six panels, `t8-a`…`t8-f`.

The owner accepted every recommendation from the review (2026-11-10):

1. **The grid's veto bar stays as shipped.** `t8-a` redraws it: tangerine VETOED fill, a
   tangerine `VETO USED · <name>` pill under the heading, and the other bars dashed and
   disabled once the veto is spent. The frame didn't know a per-tile bar already existed
   (its note says the bar is new). None of that is built. The shipped bar keeps `bg-peach`
   (tangerine is reserved for "Send my votes"), `rounded-full`, the `MOVE VETO` caption and
   the move-the-veto behaviour. The only change is that the bar now shares its row with
   More. It's ~109px at 360 wide and ~89px at 320, and `MOVE VETO` still fits.
2. **A full row of tallest tiles doesn't fit at 360×640, and that's accepted.** The tallest
   cell (2-line name, address, 4-line description, bar row) is ~241px at 360, against a
   204px track. Clamping to 3 lines still gives ~224px. Raising the 200px floor would mean
   raising `.viewport-column`'s 640px gate, and 375×667 would lose the clamp. So the clamp
   stays at 4 lines, and the first row's bar row may need a short scroll inside the track
   at 360×640. §A.4 and §5 are amended to match. Stage 2 measures it.
3. **Deck card: 12px/1.4, clamped to 3 lines, and More goes in the deck's header row.**
   `t8-d`'s card body (14px/1.45 × 4 lines + a 44px More row) is ~222px. With the photo's
   72px floor that's ~294px against a ~216px slot at 360×640. More, the last child of an
   `overflow-hidden` card, is the part that would be clipped away. At 12px × 3 the card is
   ~208px and fits. More sits beside the `n / count` counter, outside the card, as the same
   44×44 white sticker button the grid uses.
4. **No drag can start from More.** Ruling 3 takes More off the card, so the frame's "a
   press on More that moves >10px becomes a drag" doesn't apply. Stage 0's
   `[data-no-swipe]` early return stays as a cheap guard for any control later added to the
   card. It must also cover the hook's capture-phase click listener, which otherwise turns
   any tap on the card into a pick.
5. **The sheet closes on ✕ and Esc only.** On `/join`, browser back leaves the ballot, and
   making back close the sheet needs a pushed history entry, i.e. a navigation. Plan
   Stage 1 and the `/join` rule forbid that. Back keeps its current behaviour. As drawn,
   the scrim swallows taps without closing the sheet.
6. **No "+ Add your own" ballot tile.** `t8-a` redraws it. That's t7 ruling (7): co-creation
   is Post-MVP.
7. **More renders on every tile**, including one with no description and no address
   (`t8-a`'s Sushi Enya). Every VETO bar in a row keeps the same width, and the sheet still
   shows the full name (the tile clamps it to 2 lines) and the photo.
8. **`03` keeps its stacked ▲▼ reorder buttons.** `t8-f` draws only ⠿ and ✕, but ⠿ is
   hidden on touch and `Sortable` is HTML5-drag-only, so ▲▼ is the only touch path. `03`
   only gains the description.
9. **The grid tile's other metrics stay as shipped.** `t8-a` also redraws the address at
   10px/400 (shipped: 10.5px/500), tile padding at 11px (shipped: 10px) and the internal gap
   at 7px (shipped: 6px). Only the description block is new.

**Accepted as drawn:**
- Description type is Instrument Sans (`--font-sans`), not the Inter the prompt named.
- A vetoed tile's description and address go `text-muted` (#5E6D64, 5.6:1), not
  `text-faint`, which fails 4.5:1 for body text.
- Even rows come from the tile's existing `flex-1` stretch. Nothing reserves a description
  slot.
- More is a 44×44 white sticker button reading **More**, `aria-label="More about <name>"`
  and `aria-haspopup="dialog"`. Pressed is yellow and sinks 1px. Keyboard focus uses the
  app's global violet `:focus-visible` ring, not the frame's per-control 3px one.
- The sheet's layout and type as drawn: rows that don't apply are left out without gaps,
  focus goes to ✕ on open and back to the opener on close, and the OSM credit shows only
  for an OSM-derived option. **Website ↗** is white, and the build adds
  `target="_blank" rel="noopener noreferrer"`, which the frame's markup lacks (t7 ruling 4).
- On `02`, a typed option with a description reads just "typed by you", dropping
  "· description added", because the description now shows under it.
- On `03`, a row with neither details nor a description shows only the name ("No details
  yet" goes).
- Frame-only chrome isn't built: the bare status line (D-047's panel stays) and the full
  footer on `/join`.

**Not drawn, built by combining drawn parts** (stop point C applies if one turns out to
need new vocabulary):
- Grid with vetoes off: More alone in its row, right-aligned.
- Sheet with a description but no address, or an address but no description.
- Sheet opened from the deck, with focus returning to the deck's More.
- `02` "added, looking": the shimmer bar replaces the meta line, and there's no
  description slot.
- `02e` when a description arrives on an assisted card that already has an address: it
  fades in over the bars.
- The sheet at 320 wide, and with a 2-line name.

### A.6 DESIGN-SPEC

Add a `### t8 longer descriptions` section to `docs/design/DESIGN-SPEC.md` after `t7`. Give
the frame path, the per-surface clamp, size and line-height, the rulings, and every build
deviation. Edit the `t7` section's **Cards** and **Ballot** bullets in place so they no longer
say the address *takes* the description's line. Point them at `t8`.

---

# Part B — Code

No data model, migration, context or API change. `Activity.description` and its 140-grapheme
cap stay as they are. Everything here is in `lib/consensus_web/` and `assets/`.

### Stage 0 — pre-frame groundwork (can run during stop point A)

1. **`SwipeCard` hook ignores pointers that start on a control.** `assets/js/hooks.js`'s
   `pointerdown` handler doesn't check `e.target` today, so a button inside the deck card
   would start a drag, and a tap on it would count as a pick. Add an early return for
   `e.target.closest("[data-no-swipe]")`. This is harmless before any control exists. Guard
   the hook's capture-phase `click` listener the same way, or a tap on such a control still
   picks the card. (§A.5 ruling 3 puts the deck's More outside the card, so nothing uses
   this yet. It stays as a guard per ruling 4.)
2. **Split the line helpers in `JoinLive.Ballot`.** Replace `tile_meta_line/1` (address **or**
   description) with two things: the address (rendered by `ItemDetails`) and a
   `description/1` that returns the text or `nil`. The `"No details yet"` fallback stays only
   where the frame keeps it. A `nil` description renders nothing, not an empty block.

### Stage 1 — the more sheet (ballot only)

- New assign `@info_id` (an activity id or `nil`) on `JoinLive.Ballot`. The events are
  `open_info` (with `phx-value-id`, validated against `@group.activities` and ignored if
  unknown) and `close_info`. Server-side so the sheet renders once, not once per tile, and
  so tests can assert on it. The ballot's selections live in socket assigns, so opening the
  sheet has to be a state of this LiveView, never a navigation (CLAUDE.md, the `/join`
  tree).
- **No write path.** `open_info`/`close_info` never touch `@approved`, `@veto_id`, deck
  position or history. A test asserts that.
- Render it as a new function component, probably `ConsensusWeb.ItemDetails.info_sheet/1` so
  the chip/address/credit rendering stays in one module. Use the frame's layout, `role="dialog"`
  `aria-modal="true"`, labelled by the name, focus moved to it on open and back to the
  triggering control on close (`JS.focus` / `JS.pop_focus`; focus lands on the ✕), and ✕ or
  Escape closes it. Nothing else does: the scrim swallows taps, and browser back is not
  intercepted and pushes no history entry (§A.5 ruling 5). Website as
  `target="_blank" rel="noopener noreferrer"`. If *this* option's details came from OSM
  (`ItemDetails.osm_derived?/1` on the one activity), the OSM credit goes in the sheet too
  (`ItemDetails.osm_credit/1`, new tab).
- The `UnsavedBallot` hook must not treat opening or closing the sheet as navigation.

### Stage 2 — grid tile and deck card

- **Grid tile** (`grid_view/1`): name (`line-clamp-2`, as now), then the address line, and
  then the description as its own block: Instrument Sans 400 12px/1.4, `line-clamp-4`,
  `text-ink-soft`. The address keeps the shipped mono 10.5px/500 treatment, with no chip,
  which stays on the photo (§A.5 ruling 9). So do the tile's padding and gaps. The cell's
  bottom row becomes `flex gap-1.5`: the shipped VETO bar (`flex-1 min-w-0`, unchanged look,
  captions and move behaviour, ruling 1) and then the 44×44 **More** button. More is never
  inside the approve `<button>`, carries `aria-label="More about <name>"` and
  `aria-haspopup="dialog"`, and is white with a yellow press, never tangerine. It renders on
  **every** tile (ruling 7). With vetoes off it sits alone in the row, right-aligned. Vetoed
  state: the description and the address go `text-muted`, not `text-faint`. Keep `min-w-0`
  and the `flex-1` stretch, both load-bearing per the comments. No "+ Add your own" tile
  (ruling 6).
- **Deck card**: `Sticker.deck_stack/1`'s `detail` stays 12px/1.4, and its clamp goes from
  `line-clamp-2` to `line-clamp-3` (§A.5 ruling 3). Not the frame's 14px × 4, which overflows
  the ~216px slot at 360×640 and clips More. **More is not on the card.** It goes in
  `deck_view/1`'s header row beside the `n / count` counter, as the grid's 44×44 button.
  Check at 360×640 that the card still fits its slot with the photo at its `min-h-[72px]`
  floor; the moduledoc's measured overflows are the regression list.

### Stage 3 — `02` and `03`

- **`02`** (`GroupLive.Options` pool card): a description block under the detail line or the
  provenance line: 12px/1.4, `line-clamp-2`, `text-muted`, 4px under it. A typed row with a
  description drops `provenance_text/2`'s "· description added" suffix and reads "typed by
  you". During the `02e` enriching interval, follow `t8-e`: two shimmer bars in the slot,
  then the text fades in, or the slot collapses in the existing 180ms.
  The pool is a stream, so the card only re-renders when its item is re-streamed. Check that
  a link-preview fill (which sets `description`) already re-streams the row. It does for the
  provenance line, so it should for this too.
- **`03`** (`GroupLive.Review`): stop hiding the description when `has_detail_line?/1` is true.
  Render the detail line and then the clamped description (same type as `02`), before and
  after publish. A row with neither shows only the name ("No details yet" goes). The stacked
  ▲▼ buttons stay before publish (§A.5 ruling 8).

### Stage 4 — docs

- **D-062** in `docs/decisions.md`. A description is never displaced by details. It clamps per
  surface, and the ballot's full text is a read-only sheet that holds no vote state. **Edit
  D-060 in place** (the `t7-e`/`t7-f` lines that say the address takes the description's line,
  with a D-062 note), per the working agreement.
- DESIGN-SPEC per §A.6.
- Grep README, CLAUDE.md and TODO.md for `tile_meta_line`, "address takes", and the test
  count, and fix every hit. CLAUDE.md's D-060 paragraph says details render "as a chip +
  address on cards and the ballot", so add that the description stays.

## 3. Tests

In `test/consensus_web/live/join_live/ballot_test.exs`:

- A tile for an option with an address **and** a description renders both (the regression
  this issue is about).
- A tile with neither renders no empty description element.
- `open_info` renders the sheet with the full 140-grapheme description, the address and a
  `target="_blank"` website link. `close_info` removes it. Neither changes the picked/veto
  counter or `#ballot-status-region`.
- `open_info` with an id from another group is ignored and doesn't crash.
- The more control is not a descendant of the approve button (assert by element structure:
  `#activity-<id> > button[phx-click=toggle_approve]` doesn't contain it).
- Deck view: the same sheet opens from the More in the deck's header row, which is not
  inside `#deck-card-<id>`.
- A tile with no description and no address still renders More (§A.5 ruling 7).
- With `veto_allowed: false`, More renders and no VETO bar does.
- `aria-label` names the option.

In `review_test.exs` / `options_test.exs`: an option with category + address + description
shows all three on `03` and `02`, before and after publish for `03`.

`chrome_test.exs` and the `/join` footer rules don't change, because the sheet has no links
except new-tab ones. Run `mix precommit` with `MIX_TEST_PARTITION` set.

## 4. Verification in the browser

Use `consensus-dev` (`.claude/launch.json`). Seed a group whose options cover t8-a's six cases
(the `ScriptedProvider`'s `vernick` gives an address, then type a 140-character description on
`02b`), publish, and open `/join/:slug/vote` as a guest.

- At 375×812 and 360×640: tiles in a row have equal heights and aligned VETO bars, clamps
  end in an ellipsis. At 375×812 at least one full row is visible above "Send my votes". At
  360×640 the first row's text is visible, and its bar row is at most a short scroll away
  inside the track (§A.5 ruling 2; record the measured overflow).
- `elementFromPoint` over the more control returns the control, not the approve button.
  Tapping it opens the sheet, and the PICKED count doesn't change.
- Deck: More in the header row opens the sheet without picking. At 360×640 the card with a
  3-line description fits its slot, and nothing paints over PASS / VETO / PICK.
- Sheet: Escape and close both return focus. The website opens a new tab and the ballot keeps
  its selections.
- `02` and `03` at 375 wide: chip + address and description both show, and nothing wraps
  mid-phrase.
- Dark mode isn't a thing here (the canvas is fixed), so skip it.

Screenshot each surface for the PR.

## 5. Risks

- **Taller tiles mean fewer options per screen.** Six options was already a scroll at 640px
  tall. Accepted: the pool already scrolls, and reading beats density. The clamp did push the
  tallest row (~241px) past the 204px track at 360×640. Raised at stop point B and accepted
  as a short in-track scroll, because raising the floor would mean raising the 640px gate
  (§A.5 ruling 2).
- **A third view of an option.** It's read-only by §2 decision 3 so it can't drift from D-044's
  shared selection. Adding vote buttons later is a new decision, not a tweak.
- **Stream re-render on `02`.** Covered in stage 3.
