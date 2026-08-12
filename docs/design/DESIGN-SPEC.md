# Consensus — visual spec (from Claude Design "Consensus · Create & Share", turn 1, options 1a + 1b)

This file is the **single source of visual truth** for the creation-side build. It was derived
from `docs/design/create-and-share.dc.html` (the imported design doc) and its per-screen
extracts in `docs/design/screens/`.

## Looking at the target

```bash
python3 -m http.server 4999 --directory docs/design
```

Then open one screen at a time — each file is a standalone, plain-HTML render of exactly one
design frame at its native 340×700 (phone) size:

| Target | Reference URL | Build status |
|---|---|---|
| header + footer (**ratified**) | <http://localhost:4999/screens/4a-0-pair-in-the-footer-header-drops-to-recommended.html> | in scope |
| header + footer (rejected alternative) | <http://localhost:4999/screens/4b-0-pair-in-the-header-beside.html> | reference only |
| `00a` intro / splash | <http://localhost:4999/screens/1b-0-00a-intro-start-page.html> | in scope |
| `00b` how it works | <http://localhost:4999/screens/1b-1-00b-how-it-works-from-footer.html> | in scope |
| `00` home | <http://localhost:4999/screens/1b-2-00-home-start-page-1a.html> | in scope |
| `00c` feedback form | <http://localhost:4999/screens/1b-3-00c-feedback-form-from-any-header.html> | in scope |
| desktop organizer console | <http://localhost:4999/screens/1b-4-made-with-in-philadelphia.html> | in scope (lowest priority) |
| `01` setup | <http://localhost:4999/screens/1a-0-01-setup.html> | in scope |
| `02` add options | <http://localhost:4999/screens/1a-1-02-add-options-manual-mvp.html> | in scope |
| `02b` edit an option | <http://localhost:4999/screens/1a-2-02b-edit-an-option-full-screen.html> | in scope |
| `03` review pool | <http://localhost:4999/screens/1a-4-03-review-pool.html> | in scope |
| `04` share | <http://localhost:4999/screens/1a-5-04-share.html> | in scope |
| swipe deck | <http://localhost:4999/screens/1c-0-swipe-deck-kept-in-play.html> | in scope (a toggle, not the default) |
| sticker grid (the default ballot) | <http://localhost:4999/screens/1c-1-sticker-grid-kept-in-play.html> | in scope |
| `05` / `05b` live results | `1a-6-…`, `1a-7-…` | shipped (voting side) |
| `06` recipient's first view | `1a-8-…` | shipped (voting side) |
| phase-2 discover | `1a-3-…` | **out of scope** (Post-MVP, PRD scope discipline) |
| share alternatives, join copy tone | `1d-…`, `1e-…` | reference only |

The desktop-console row's filename is a red herring: the extractor captions each frame from the
last centred line inside it, and that frame's last centred line is its own footer. `1b-4` is the
1280×790 console.

Two later imports sit on top of this file. [IMPORT-NOTES.md](IMPORT-NOTES.md) is the literal spec
for everything the 2026-08-08 re-import added — the global header and footer, `00b`, `00c`, the
swipe deck, and the token deltas. Where that import contradicts itself or contradicts a settled
decision in `docs/decisions.md`, the rulings in
[docs/plans/chrome-and-feedback.md](../plans/chrome-and-feedback.md) settle it and beat the frame.

The design frames are static mockups. Two things in them are *not* literal targets:

- `{{ countdown }}` and `{{ votedLabel }}` on the home card are unrendered template holes.
  They mean "a live relative countdown" (e.g. `4h 12m`) and "a voted-state label".
- The `9:41` / `▮▮▮` strip at the top of every frame is an iOS status bar drawn into the
  mockup. **Do not build it.** Our pages render in a real browser that has its own chrome.
- `340×700` is the mockup's phone frame, not a fixed app width. Our pages are responsive:
  they should match the design at a ~390px-wide viewport and stay sane wider.

## Tokens

Put these in `assets/css/app.css` as CSS custom properties and Tailwind v4 `@theme` entries.

| Token | Value | Used for |
|---|---|---|
| `--ink` | `#17211C` | every border, all primary text, all hard shadows |
| `--ink-soft` | `#3B4A42` | secondary body text |
| `--muted` | `#5E6D64` | labels, meta, captions |
| `--faint` | `#8A968E` | disabled chip text |
| `--canvas` | `#DDF0E2` | the page behind the app (mint) |
| `--surface` | `#F7FBF8` | app background inside a screen |
| `--white` | `#FFFFFF` | cards, inputs |
| `--tangerine` | `#FF6A2B` | **the one forward action per screen**, and only that |
| `--violet` | `#6B46F0` | votes, live state, progress fill |
| `--violet-tint` | `#F3EFFE` | hover fill on outline chips |
| `--violet-soft` | `#D6CCFB` | avatar / badge fills |
| `--mint` | `#B9EFC9` | success, "added", input focus shadow |
| `--mint-soft` | `#C9E8D2` | photo placeholder stripes |
| `--yellow` | `#FFD84D` | secondary action (Add, Save, Use this), hover/press fill (Edit pill — white at rest, D-052) |
| `--yellow-soft` | `#FFE3A8` | badge fills |
| `--peach` | `#FFC2A3` | avatar fill |

Fonts (Google Fonts, `display=swap`):
`Instrument Sans` 400–700 for everything; `DM Mono` 400/500 for time, counts, urls, ALL-CAPS
labels. Self-host or `<link>` — either is fine, but the family names must match.

## Sticker chrome — the whole look in five rules

1. **2px solid `--ink` border** on every card, chip, input, button, avatar.
2. **Hard offset shadow, no blur:** `box-shadow: Npx Npx 0 var(--ink)`. N = 6 for a phone
   frame, 4 for a primary button, 3 for a card/input, 2 for a small chip/row.
3. **Radii:** 34px phone frame · 20px large card · 14–18px button/input/card · 99px pill.
4. **Press/hover on anything clickable:** `transform: translate(1px, 1px)` and the shadow
   loses 1px. Nothing fades, nothing scales.
5. **Fields carry a mint shadow at rest**, not ink: `box-shadow: 3px 3px 0 var(--mint)`. This
   is a resting state, not a focus state — every field in frames `01` and `02b` has it, and
   only one of them is drawn focused. Focus adds the `:focus-visible` violet outline on top.
   One scoped exception: **assist-owned fields rest on violet-soft** (`2px 2px 0 #D6CCFB` on
   the area prompt's field) — frame t5 draws the violet family as the assist's accent, and
   the deviation is deliberate and confined to assist surfaces (D-052; see the `02` assist
   states below).

Section labels are `DM Mono`, 11px, 600, `letter-spacing:.06em`, `uppercase`, `--muted`.

## Screens

### `00a` intro (public splash, signed out) — `/`
Mint (`--canvas`) full-bleed. Vertically centred stack: `CONSENSUS` eyebrow (DM Mono, 11px,
600, `letter-spacing:.1em`, uppercase) · `h1` 40px/1.02, 700, `letter-spacing:-.035em`,
two lines "Decide / and Dine" (the frame said "Decide / together, / in minutes."; the
shipped headline matches the social card's wordmark instead) · a 14.5px paragraph capped at 250px:
"Stop the group chat spiral. Put the options up, let everyone rank, get an answer."

Then three white sticker rows (3px shadow, 15px radius), each a numbered 30px rounded-square
badge (`1` yellow, `2` violet-soft, `3` peach; DM Mono 700 12px) + a 14px/700 title and an
11.5px muted line:
1. **Add anything** — Type a name or paste a link.
2. **Share one link** — No app, no account to vote.
3. **Everyone ranks** — Anonymous. One winner, no debate.

Footer: tangerine **Get started** button (full width, 16px pad, 16px radius, 4px shadow)
→ registration. Below it, centred 12.5px: `Have a link? Open it →`.

> **Copy substitution, shipped.** In the frame that line links to `#1b`, the mockup's own
> ballot. There is no such route in the app — a ballot is `/join/:slug/vote` and the slug
> only exists in the link the voter was sent — so the built version pointed it at
> `/users/log-in`, which is precisely the screen PRD product invariant 1 says a voter must
> never be shown. It now reads `Sent a link? Open that link — voting needs no account.
> How it works →`. Same slot, same treatment; the destination is `/how-it-works`.

> **The button's label is `Start something`, not the frame's `Get started` (D-047 §4).** The
> same `~p"/users/register"` was called `Get started` here and `Start something` on
> `/how-it-works` and `/privacy` — one destination, two names, one tap apart. The front door
> is where most readers meet the action first, so it is the one that moved. The `⋯` menu's
> signed-out entry, which had been missed, moved with it in the consolidation pass.

### `00b` how it works — `/how-it-works`
`--surface` background. Title block (7px gap): `h1` 30px/1.05, 700, `letter-spacing:-.03em`
"How it works", then a 13.5px/1.45 `--ink-soft` sub-line. Then a vertical timeline (four
steps in the frame, **five** as built — see the deviation below): a **36px** numbered badge
(2px ink, **10px** radius — `00a`'s three badges are 9px; the frames disagree and 10px wins
here — DM Mono 700 13px, `shadow-sticker-2`, fills cycling yellow → violet-soft → peach →
yellow-soft → mint), a 2px vertical 5-on/5-off ink dash between badges but
not after the last, and copy at 15px/700 + 12.5px/1.45 `--muted`. Then a white "Good to know"
card (16px radius, 3px shadow, 14px pad) with an `.eyebrow` and three bullets whose `·` is
`--violet` 700. Then the one tangerine **Start something** button. The full geometry is
[IMPORT-NOTES.md](IMPORT-NOTES.md) §5.

> **Copy substitution, shipped.** Three of the frame's own sentences are false of this
> product and are not built (plan ruling 5 / IMPORT-NOTES Q-D / D-042). The frame's step 1
> says *"Anyone you invite can throw theirs in too"* — friends adding options to somebody
> else's pool is Post-MVP, and the pool freezes the moment voting opens (invariant 16 /
> D-037). Its step 3 says *"Drag your top three"* — the ballot is approval voting with veto
> elimination (D-034), and nothing is dragged. Its third "Good to know" bullet says *"Change
> your ranking any time before the timer ends"* — a cast ballot is locked (D-036). The
> structure, the rhythm and every measurement above are the frame's; the sentences
> are rewritten to be true, and the two irreversible facts the frame denied are stated in the
> "Good to know" card instead. Its second bullet also loses the word "nudge", which has no
> implementation. Pinned by `refute` assertions in
> `test/consensus_web/live/how_it_works_live_test.exs`.

> **A fifth step, and a 36px badge (D-046).** The frame's four steps begin at "Add the
> options", so nothing anywhere on the page said the organizer *names the session and sets the
> hard deadline* — then the frame's own last step opens "When the timer runs out…", a definite
> article for an object no earlier sentence introduces, and the single tangerine CTA drops the
> reader onto `/groups/new`, whose only two inputs are exactly those two things. A page that
> describes a four-step product and hands the reader an unannounced fifth screen is the
> "unpredictable outcome" failure, and it is the same standard the CTA's own sub-line already
> applies to accounts. Step 1 is now "Name it and pick a deadline"; the last reads "the
> deadline you set", so its definite article has an antecedent. The badge is 36px, not 32:
> §5.2's 32 is the content box inside a 2px border each side, and this is the element repeated
> on every row that carries the timeline's rhythm.

> **The CTA knows who is reading it.** The frame's **Start something** links to `#1b`, the
> mockup's start page. Signed in it goes to `/groups/new`; signed out it goes to
> `/users/register`, with an 11.5px muted line beneath saying what an account costs and that
> voting never needs one.

### `00c` feedback — `/feedback`
`--surface` background. `h1` 27px/1.06, 700, `letter-spacing:-.025em`. Mood row: two 36px
circles (20px face SVGs, the same two mouth paths as the footer pair), the picked one filled
`--mint`/`--peach` with a 2px ink border and `shadow-sticker-2`, the other white at 55% opacity
with an `ink/35` border and no shadow, then an 11.5px `--muted` caption. Then Name, Email and
"What happened" in the app's standard field chrome, with a `0/600` DM Mono counter on the last
one's label row. Then a dashed `ink/35` row holding the default-on "include the screen I was
on" checkbox. Then a white action bar with a 2px ink top border, `sticky bottom-0` above the
global footer. Geometry: [IMPORT-NOTES.md](IMPORT-NOTES.md) §6.

> **Three deliberate deviations from the frame.** The frame's **Cancel** button is not built:
> it resolves to the same route as the global header's `‹`, which plan ruling 1 names as the
> duplicate back affordance this work exists to remove. The action bar is the one tangerine
> **Send feedback**. The checkbox's parenthetical `(Dinner Friday? · voting)` is a session
> title and status, and is replaced by a **route-derived label** — `(Home)`,
> `(Adding options)` — with the literal path on a small mono line beneath. Resolving a real
> session title from a path any visitor can type would print a stranger's session title onto
> a signed-out page; the label is computed from the shape of the path alone, and the path is
> what actually gets stored (D-042). And the frame carries `FEEDBACK` in the **header** slot,
> which plan ruling 9 reserves for state rather than the page's name, so that slot is empty
> and the body opens straight on the `h1` with no eyebrow standing in for it.

> **§6.5's pinned action bar is built as pinned, and one review round shipped it in flow.**
> The argument for flow was that a nested scroller under a sticky header is the thing a phone
> handles worst — true, and not what §6.5 asks for. In flow the screen's single forward action
> measured 84px below the fold at 420×700 and 159px below it at 360×640. `sticky bottom-0`
> needs no nested scroller, and nothing competes with it for the viewport edge because
> `Chrome.footer/1` is deliberately not sticky (D-041): at the bottom of the scroll the bar
> ends exactly where the footer begins.

> **Two more deviations, both consequences of pinning it, both D-046.** (1) **The consent row
> moved into the bar**, above the button, where §6.4 draws it as the last child of the scroll
> body. A `sticky` Send is reachable without scrolling by construction, so a consent row
> anywhere in the body can be skipped unseen: measured at 420×700 with `scrollY=0`, the row's
> top sat at 663.6 in a 700px viewport with everything below 606 behind the opaque bar and
> `elementFromPoint` at the label's centre returning the bar, while Send sat at 620–680 fully
> hit-testable. A default-on checkbox the sender cannot see is the same lie as one the app
> ignores. The row keeps §6.4's geometry, its 44px label and the path line. (2) **The scroll
> body reserves the bar's height** (`pb-[172px]`); without it the opaque bar deleted that much
> live content — 16.4px of a 110px textarea visible at 360×640, and focusing it did not scroll,
> because Chrome knows nothing about an overlay.

> **Two metric deviations on this screen, one fixed and one recorded.** The `What happened`
> textarea is **138px**, not the 110 that shipped: §6.3's `min-height:110px` is a *content* box
> on top of `padding:14px` and a 2px border each side, and the app's box model is border-box.
> Its type is **16px**, not §6.3's `400 13.5px/1.45` — iOS Safari zooms the page on focus below
> 16px and does not zoom back, and a static mockup measured in a design tool is not evidence
> about that (CLAUDE.md invariant 18). **`Send feedback` is deliberately left at the app-wide
> primary metric** — 60px tall, 16px radius, `shadow-sticker-4` — against the frame's 48 / 15 /
> `shadow-sticker-3`. `<.button variant="primary">` is shared by every screen; overriding the
> primitive on one screen buys frame fidelity at the cost of the thing a design system is for.

> **That button deviation is system-wide, not a `00c` exception — recorded here for all three
> instances (D-047).** The frames give the same control three different metrics: §6.5's
> `Send feedback` computes 48px tall at `700 14.5px` / 15px radius / `3px 3px 0`, §8's
> `Send my votes` 51px at `700 15px` / 15px radius, and §9.4's `00b` CTA `700 15.5px`. The app
> renders one primitive at 60px / 16px radius / `700 16px` / `shadow-sticker-4` on all of
> them. Listing only the `00c` instance made it read as one recorded exception beside two
> silent ones; it is one decision, taken once, and it holds wherever
> `<.button variant="primary">` appears. Changing it means changing the primitive, which is a
> new `D-0NN`, not a per-screen override.

> **Two more `00c` deviations, both settled after critic round 2.** The **mood pair is 40px**,
> not the 36 that shipped: §6.2's `width:36px; border-top-width:2px` is a content box, so the
> frame paints 40, and D-041's amended rule re-cuts a control to the frame's painted total
> wherever no container dimension depends on it. The label around each face went 44 → 48 in the
> same change, which is what keeps the frame's 9px circle-to-circle gutter (a 40px circle in a
> 44px label collapses it to 5px). And the **capture-consent row is drawn solid**, where line 43
> of the frame draws `2px dashed rgba(23,33,28,.35)`. In this repo dashed is the documented "not
> built yet" treatment (CLAUDE.md invariant 12; D-046 draws every inert control that way; D-047
> changed `03 review`'s veto row for exactly this reason). That row is a live, functional,
> default-on consent control, and it is the one place where frame `00c` and the app's own
> convention genuinely disagree. The convention wins, because it is the one a reader of this app
> has been taught everywhere else.

> **Post-submit, undrawn in the design and settled by plan ruling 7:** the form is replaced
> in place by a full-page thank-you — a mint sticker card with an ink check badge, a line
> saying what was stored and whether the screen was included, and one tangerine button back
> to the `?return_to=` the face was tapped on. The header's `‹` is dropped in that state, so
> there is one way back rather than two. A flash over a screen that still looks like the form
> reads as "nothing happened", which is the failure this whole piece of work removes.

### `00` home (signed in) — `/`
`--surface` background. Header row: `h1` "Consensus" 27px/700 `letter-spacing:-.025em` and a
34px circular peach avatar with the user's initial (2px ink border, 700 13px).

Tangerine **Start something ＋** bar (16px radius, 4px shadow, `justify-content: space-between`).

Then `ACTIVE` label and a card per active group — white, 16px radius, 3px shadow, 13/14px pad:
- row 1: 15px/700 title, and on the right a DM Mono 11px countdown in `--violet`.
- row 2: 11.5px muted "You're organizing · <voted label>" and a status pill on the right —
  mint `VOTING`, yellow `YOUR TURN` (1.5px border, 99px radius, 9.5px/600).

Then `PAST` label and a de-emphasised card per finished/cancelled group — border
`rgba(23,33,28,.3)`, background `rgba(255,255,255,.6)`, no shadow, a `›` chevron on the right,
title 14px/700 in `--ink-soft`, subtitle 11px muted ("Kismet won · Jul 24").

Empty state (no groups yet) is not in the design — render the `ACTIVE` label with a dashed
sticker row reading "Nothing yet. Start something above."

### `01` setup — `/groups/new`
Wizard step 1 of 3. Header: 34px circular `‹` back button, a 3-segment progress bar (6px tall,
99px radius; filled `--violet`, unfilled `rgba(23,33,28,.12)`), and `1/3` in DM Mono 10px.

- `h1` "What's the plan?" 31px/1.08, 700, `letter-spacing:-.025em`, breaking after "the".
- **SESSION TITLE** — one text input, 16px radius, 17px/600 text, `3px 3px 0 var(--mint)`.
- **VOTES CLOSE** — pill chips, 2px ink border, 99px radius, 13px. The selected chip is
  `--violet` filled, white text, 600, `2px 2px 0 var(--ink)`. Unselected are white and
  hover to `--violet-tint`. **Exactly three chips, computed live in the user's timezone:**
  `5pm this evening` · `5pm tomorrow` · `next Thursday at noon`. Label them the way the design
  does — short and human (`Tonight 5pm`, `Tomorrow 5pm`, `Thu noon`). The design also shows a
  dashed `Custom…` chip — **render it disabled/greyed for now**, it is explicitly deferred.
  Helper line under the chips: "Hard deadline. Voting locks itself and picks the winner."
  If a chip's time has already passed today, it still means the *next* occurrence.
  **Deviation (2026-08-11, not in the frame):** a warning line renders *above* the
  chips — a 20px `--tangerine` circle (2px ink border) holding a white bold `!`, then
  "Pick when votes close — the session can't run without an end time." (13px/500,
  `--tangerine`). The frame's bare chip row read as optional filters, and organizers only
  learned the deadline was required when submit failed; the helper line below stays the
  mechanics footnote. This is the one place on this screen where tangerine appears twice
  (here and on **Add the options →**) — deliberate, and the same licence
  `CoreComponents.error/1` already takes: tangerine is this system's alert colour, and the
  submit-time deadline error directly below is tangerine too. The badge is
  `aria-hidden` — the sentence beside it is the accessible text.
- **GROUP** — overlapping 30px avatars (−8px margin) with a `+N` bubble and a 12px muted
  caption. Saved friend groups are Post-MVP: show the organizer's own avatar and the caption
  "Just you so far · invite by link".
- Footer: tangerine **Pick a neighborhood →** in the design. Our step 2 is options, not
  location, so the button reads **Add the options →**.

### `02` add options — `/groups/:id/options`
Step 2 of 3 (two progress segments filled). **Design frame t5 ("5 · Assisted Add", six 02
panels in the same Claude Design file) is the newest ground truth for this screen** —
transcribed in the assisted-add frame review and bound by
[assisted-add-ux-brief.md](assisted-add-ux-brief.md); where t5 and the original `1a-1` frame
disagree, t5 wins (D-052).

- `h1` "Add the options" — built at 28px/1.1 (the 29px original wrapped to two lines in the
  app's column; one blind A/B round flagged the wrap as a tell and the size moved).
- **ACTIVITY TYPE** — horizontally scrolling chips. `Restaurant` is selected: ink-filled,
  white text. `Bars` and `Movies` are **not clickable** (Post-MVP) and draw in t5's *quiet*
  treatment — a fine `rgba(23,33,28,.38)` dash and faint text — not the full-ink dashed
  `01` uses for `Custom…`. **No caption under the chips**: the original frame's
  "Restaurants first. More types as we grow." appears in no t5 panel (the helper budget
  moved to the assist's line under the input) and is not built (D-052).
- **TYPE A NAME OR PASTE A LINK** — a text input (placeholder `Name or link`, 16px computed,
  mint shadow at rest) and a yellow **Add** button. Helper line beneath, 11.5px `--muted`:
  *"Type a name and we'll try to find its link. Or paste one yourself."* (the brief's F4 swap;
  the old "Restaurant search coming soon…" line is gone). Pasting a URL fetches the page and
  fills image, title and description; all three stay editable. A typed non-URL becomes a name
  with no details — and fires one background lookup (the assist, below). **Nothing fires
  while typing** — no dropdown, no per-keystroke state, ever (brief constraint 1).
- The pool list. Each row: 2px ink border, 14px radius, `2px 2px 0 var(--ink)`, a 24px
  rounded-square position badge (DM Mono 700 11px, fill cycles mint → yellow-soft →
  violet-soft), the name at 14px/700, a DM Mono 10.5px provenance line
  ("typed by you · no details yet" / "link · photo + description pulled"), a **white**
  `✎ Edit` pill and a muted `✕` that turns tangerine on hover.
- Sticky footer with a 2px ink top border: "N in the pool" 15px/700 over an 11px muted
  "N yours" (both frames word it `yours`, not "added by you"; the "· N from friends" half
  is Post-MVP sample garnish and is not built), and a tangerine **Review →**.

> **The `✎ Edit` pill is white at rest, yellow only on hover/press (D-052).** Both the
> original `1a-1` frame and every t5 panel draw the resting pill white with the 2px ink
> outline and a `hover: background:#FFD84D` rule — the one yellow pill in each drawing
> carries the *pressed* treatment (translate + collapsed shadow), i.e. it is the same
> control illustrated mid-hover, not a yellow resting state. Solid yellow at rest was an
> app deviation, now corrected; yellow remains the fill of the real actions (Add / Save /
> Use this). An earlier revision of this file called the pill yellow — that read the
> hover illustration as the resting state.

> **The add form is a sticky dock; the page stays the scroller (D-052).** Every t5 panel
> stages a fixed-height device with the pool sliding beneath a fixed input. The app pins
> the input + helper `sticky top-[48px]` flush under the global chrome header instead: the
> h1 and type chips scroll away above it, and the pool passes beneath. The brief's
> constraint 5 — the input stays reachable for the next option while a suggestion is
> showing — is the operative clause and the dock satisfies it at every viewport height; a
> recorded divergence from the frame's fixed-height composition, not drift.

#### The assist states (t5, panels 02b–02f)

Six states of the same screen, all socket-local, none an error. **The violet family is the
assist's accent — a deliberate deviation from rule 5's "fields carry a mint shadow at
rest", scoped to assist-owned surfaces only** (slot, shimmer, enriching card, area field);
the main add input keeps its mint resting shadow in every panel and in the app. Carry the
deviation, don't "fix" it (D-052 §8).

- **Added, looking (02b)** — the new card lands instantly and its meta line renders as a
  9×132px pill of violet shimmer stripes (`#D6CCFB`/`#F1ECFE`, opacity pulsing .34→.9 over
  1.5s). If nothing comes back it cross-fades into the plain "typed by you · no details
  yet" line. **No failure state exists for this feature** — no match, provider down, 429,
  504 and timeout all render as the shimmer simply stopping.
- **One match / two–three matches (02c/02d)** — the suggestion slot attaches under the
  card: the card's corners square into it, the slot carries the shadow, `#F5F1FF` fill, a
  dashed ink top rule, `IS THIS IT?` in DM Mono with a dismiss ✕ (`title="No thanks"`).
  Rows carry **name + street address (+ a cuisine chip on the one-match shape only,
  1.5px `ink/45` border — small-pill convention) and nothing else: no rating, no price
  band, no photo, no hours, no distance** — those fields are unlicensed for display
  (research §4.6, brief constraint 2). Three rows is the hard ceiling; dashed dividers
  between them; yellow **Use this** per row. The slot expands 180ms/fades 120ms and never
  moves the input or the Review bar; the reveal scroll is clamped so the card's own name
  row stays visible above its slot (frame-review §e-3 — the brief wins over the drawing's
  over-scroll).
- **Confirmed, enriching (02e)** — the slot collapses, the title cross-fades to the
  provider's canonical name, a 32px shimmering photo tile appears, the meta reads
  `link attached · details arriving`, Edit collapses to icon-only `✎`, and the card's
  shadow switches to **violet** (`--shadow-assist: 2px 2px 0 var(--violet)`) for the
  enriching interval — then the card is an ordinary link-enriched card, back on the ink
  shadow.
- **Dismissed** — the slot collapses and the bare typed card stands; the lookup is not
  retried for that card. Visually identical to a plain typed card; not drawn by the frame,
  by design.
- **Area prompt (02f)** — the slot shows the one-time "Where should we look?" prompt
  instead of results: a 16px `Neighborhood or city` field (violet-soft `#D6CCFB` resting
  shadow — the scoped deviation again; no `maxlength`, the changeset's 100 graphemes is
  the limit), a yellow **Save**, and a dismiss ✕ **which the drawing omits but the frame's
  own annotation and the brief both require — built** (D-052 §8). Asked once per group;
  answered → never again, dismissed → suppressed for the session, geocode failure →
  silent collapse and a later add may ask again.
- **Attribution renders in every slot state**, last child, DM Mono 9px `--faint`:
  `Places from OpenStreetMap contributors`, only the contributors phrase linked, to the
  ODbL licence. The prefix/link split and the URL come from the provider
  (`Discovery.attribution_for/1`) — nothing hardcoded in the template. Absent is not an
  option wherever suggestions render (brief constraint 3).

Not built from t5, deliberately: the friend-added card garnish (`Kismet · ALEX`,
"1 from friends") and the 5b setup-screen area-field variant with its saved-group row —
Post-MVP sample content, same class as the D-051 sample-data deviation. The panels'
in-content back circle is the global header's `‹` (D-041), and the position badge keeps
the app's shipped fill cycle rather than re-matching each panel's sample fills.

### `02b` edit an option — `/groups/:id/options/:option_id`
Full screen, not a modal. Header with a 34px `✕`, "Edit option" 15px/700, and a tangerine
12.5px **Remove** on the right.

- **PHOTO** + a right-aligned `OPTIONAL` in DM Mono 10px. A 150px-tall, 16px-radius, 3px-shadow
  box showing the image. With no image, the design's diagonal stripe placeholder:
  `repeating-linear-gradient(135deg,#D6CCFB 0 12px,#EDE7FE 12px 24px)`. When the image came
  from a pasted link, an ink pill top-left reads `PULLED FROM LINK`. Bottom-right: white
  `Replace` and `Remove` buttons (11px radius). **Images are URL-referenced only — there is
  no upload.** `Replace` asks for a new image URL.
- **NAME** — input, 15px/700.
- **DESCRIPTION** — textarea, 13.5px/1.45, `min-height:74px`, with a live `62/140` counter in
  the label row and the caption "Everyone sees this when they rank." The limit is 140 and it
  is enforced **in the changeset, never with a `maxlength` attribute** — see D-026. A browser
  counts `maxlength` in UTF-16 code units while the changeset counts graphemes, and the
  browser's way of disagreeing is to silently truncate a paste. So typing past 140 is
  *expected* to show `160/140` and refuse to save; the counter must turn `text-tangerine`
  past the limit so that reads as a limit rather than as a broken field.
- The source-link row, only when there is one: dashed 2px border, `--surface` fill, `🔗`,
  the URL truncated to one line, "photo + description auto-filled" beneath it, and a muted
  **Refetch** on the right that turns tangerine on hover.
- Footer: white **Cancel** and a flex-1 tangerine **Save option**.

### `03` review pool — `/groups/:id/review`
- `h1` "Your pool" 27px/1.1 and a 12.5px muted line "Drag to reorder. Friends can still add."
- Reorderable rows: `⠿` grip, a 36px rounded-square thumbnail (the image, or the striped
  placeholder), name 14px/700 + `Italian · $$$`-style meta at 11px, and a `✕`.
- A violet-tint (`--violet-tint`) card: "Anonymous voting" 13.5px/700 over "Nobody sees who
  picked what.", with a 46×27 violet toggle on the right (white 19px knob, 1.5px ink border).
- A dashed row: DM Mono `1×` in tangerine + "Everyone gets one veto. Vetoed places drop out."
- Footer: a DM Mono 11.5px row `CLOSES THU 6:00 PM` with the live remaining time in tangerine
  on the right, above a tangerine **Get the share link**.

> **The veto row is built solid, not dashed, and its copy is not the frame's (D-047).** In this
> repo a dashed border is the documented "not built yet" treatment — `Bars` and `Movies` on
> `02`, `Custom…` on `01`, all `disabled` and captioned "Coming soon". This row states a rule
> that is live and enforced on every ballot, one screen after those, and it sits directly under
> an equally immutable rule (`Anonymous voting · ALWAYS ON`) drawn as a solid violet card; a
> reader should not have to work out which of the two a dashed border means. It is now that
> card's sibling — same shape, a `--canvas` #DDF0E2 fill so the two are still tellable apart,
> and a mono `1×` on the right where the anonymity card has `ALWAYS ON`. **Canvas, not the
> yellow this line first recorded:** yellow was built and screenshotted first and it
> out-shouted the tangerine `Get the share link`, which is the screen's one forward action
> (the one-tangerine-per-screen rule). The `1×` renders in ink `rgb(23,33,28)` where the
> anonymity card's `ALWAYS ON` renders violet and frame `1a-4` draws `1×` in tangerine — same
> reason, and stated here so the asymmetry is on the record rather than read later as a bug.
> The sentence is
> "Everyone gets one veto. A vetoed option drops out for everyone.": "places" is dining
> vocabulary in the one sentence stating the rule (PRD product invariant 2), and it disagreed
> with what the voter is told one screen later.

### `04` share — `/groups/:id/share`
The page behind is the live session, dimmed (`filter:saturate(.5); opacity:.4`). Over it, a
bottom sheet: `--canvas` fill, 2px ink top border, `border-radius:26px 26px 32px 32px`,
`box-shadow:0 -8px 24px rgba(23,33,28,.16)`, and a 44×5 grab handle centred at the top.

- A white preview card (18px radius, 3px shadow): an 88px header with
  `linear-gradient(105deg,var(--violet) 0 55%,var(--tangerine) 55% 100%)`, the group title at
  19px/700 white and a DM Mono 12.5px line "N spots · closes Thu 6pm"; below it
  "<Organizer> set up a vote. Tap to pick." and the join URL in DM Mono 11px muted.
- A four-up row of 54px share targets (16px radius, 2px border; mint/yellow-soft/violet-soft
  and a white `···`) captioned Messages · WhatsApp · Slack · More. These are decorative in
  the design; wire the row to the Web Share API when available and hide it when not.
- Footer: an ink-filled **Copy link** (flex-1, 15px radius) and a white **QR** button.

### desktop organizer console (1b, third frame)
1280×790, `--surface`, 20px radius, a left rail and a main column. Lowest priority of the
in-scope set — build it after every phone screen is done, and treat it as a wide-viewport
layout of the same home + group data rather than a separate app.

### `1c-1` sticker grid — `/join/:slug/vote`
The full spec is `IMPORT-NOTES.md` §8. One deviation is recorded here because it is a *surface*
question rather than a metric one:

> **`#ballot-status-region` is a bordered panel where the frame draws bare type (D-047).** The
> frame prints the `2 PICKED · 1 VETO LEFT` line as one unadorned DM Mono line above the
> submit. The app had grown three near-identical centred lines there — the counter, the
> "nothing to send yet" hint and the D-036 irreversibility warning — in three barely different
> treatments, so the sentence that matters most competed for the same slot as a running count.
> They are one kind of thing (what is true about this ballot right now) and are drawn as one
> block with an explicit weight ramp. The treatment is **not invented for this screen**: a
> `rounded-2xl border-2 border-ink-30 bg-white/65` panel is this app's existing quiet
> informational surface, used ten times across `core_components.check_your_email/1`, both
> results screens and here. The counter inside it is `font-medium text-ink-soft` — DM Mono
> 11px/500 `#3B4A42`, exactly what the frame computes for that line.

### endgame · all vetoed — a takeover *state* of `/groups/:id/results` and `/join/:slug/results`

Ground truth is [all-vetoed.dc.html](all-vetoed.dc.html) (a dc-runtime doc — serve the
directory and open it over HTTP; the scene animates and the poke logic runs; the copy
lives in the `DCLogic` script at the bottom). Built as `ConsensusWeb.Endgame.AllVetoed`
over the shared `ConsensusWeb.EndgameComponents` skeleton; renders only for a
`:completed` group whose every option was vetoed with no resolution recorded (D-051).
The doc's surfaces draw at radius 18/14/13 and the app renders all of them
`rounded-2xl`, the sticker system's one surface radius — the same flattening every other
imported frame got. The scene keyframes (`flick`, `flick2`, `bob`, `ember`, `buzz`) live
in `assets/css/app.css`. Two deviations are recorded here because they are deliberate,
not drift:

> **THE CARNAGE's right-hand mono slot shows veto counts, never names (D-051 §4).** The
> doc's sample rows attribute each veto to a person (`MAYA`, `DEV`, `PRIYA`). D-035 makes
> attribution structurally impossible — `Voting.tally/1` returns totals only and no query
> in the app can say who vetoed what — so the same slot, same DM Mono treatment, carries
> `1 VETO` / `2 VETOES`. Do not "fix" this back toward the mockup; the mockup's data is
> sample copy, and the app's is the only honest value that slot can hold.

> **The fire scene is a fixed-aspect box, not a full-bleed fill.** The doc's hero is
> 346px wide, so its `xMidYMax slice` renders the 350×250 viewBox at scale ≈ 1, leaving
> a band of clear night sky above the figure's fists. At the app's wider column a
> full-bleed slice would let the width govern the scale, blow the figure up ~1.15× and
> crop the sky — so the SVG is pinned to the design's own 350:250 aspect at the card's
> height, bottom-centered, `overflow-visible` so the edge flames still bleed. This
> reproduces the doc's framing at every width.

> **The takeover lives in the app's full-bleed column, not the doc's tight card — and
> the slack that opens on a tall viewport is accepted, not drift.** (Applies to both
> takeovers.) The doc draws a floating phone card that hugs its content: its footer sits
> directly under the caption and the card ends. In the app every screen is the 440px
> column with the global footer pinned to the viewport bottom by `<main>`'s `flex-1`
> (`Layouts.app`, D-041), so a viewport taller than a short pool's content opens a band
> of bare surface between the caption and the footer. At the phone heights this product
> is designed for the content fills the viewport and the band does not exist; un-pinning
> the footer for the takeover states alone would break the one chrome rule every screen
> shares, and would make the footer jump mid-session when a rescue or a lock flips the
> takeover to the winner ending live over PubSub. Deliberately left; do not "fix" it by
> special-casing the endgame screens' layout.

### endgame · tie — the second takeover state of the same two routes

Ground truth is [tie.dc.html](tie.dc.html) (dc-runtime again — render it over HTTP; the
spin logic and the state-dependent copy live in its `DCLogic` script). Built as
`ConsensusWeb.Endgame.Tie` over the same `EndgameComponents` skeleton; renders only for
a `:completed` group with an unresolved dead heat at the top (`Voting.outcome/2`
returning `{:tie, rows}` — D-051 §2). Same radius flattening as its sibling; the scene
keyframes (`tug`, `strainL`, `strainR`, `drip`, `pulseline`) and the scene's one-off
paints (the violet radial, the `#E9DCC0` rope, the `#EDE6DC` idle lock button and
friends) live in `assets/css/app.css` as scene/UI paint the rest of the app never
reuses. Deviations, all deliberate:

> **The hero card carries the scene's aspect instead of the doc's fixed 250px.** The
> tug-of-war SVG is the doc's own full-bleed `xMidYMax slice` fill, and at the app's
> wider column a fixed height makes `slice` crop the sky — so `endgame_hero/1` gets
> `height_class="aspect-[7/5]"`, the 350×250 viewBox's own ratio, at which a `slice`
> fill is exact at any width. The opposite lever from the fire scene's fixed-aspect
> box; both mean "the card, not the viewport width, decides the scene's scale".

> **The sample data is corrected, not copied.** The caption "or run a second round with
> just these two" counts the actual tied set ("these three" on a 3-way) — and stays the
> inert mono line the doc draws, not a control. The doc's `short` row names have no
> equivalent on `Consensus.Activities.Activity`, so the full option name appears in the
> status line and the lock label. And the shuffle is server-driven state
> (`send_update_after/3` ticks), not the doc's client `setInterval` — same ~1.9s clock,
> but testable and refusal-safe mid-spin.

> **The sweat beads are invisible when their animation is not driving them**
> (`.endgame-drip { opacity: 0 }` in `app.css`) — a bead's resting position straddles
> its head's ink outline, a frame the doc's running `drip` (opacity 0 at cycle start)
> never shows but a delay window, reduced motion or any frozen frame otherwise would.
> The scene geometry itself is the source's, coordinate for coordinate — the right
> figure is the left's exact mirror in the source too, and the "asymmetric right-cheek
> mark" a steady-state still of the doc shows is the second bead mid-drip, 0.9s behind
> the first, ghosted over the cheek.

> **The full-bleed-column-versus-tight-card note in the all-vetoed section above applies
> here unchanged** — on a tall viewport the slack sits between the faint results URL and
> the pinned footer; accepted for the same reasons.

## What "matches the design" means for a critic

Compare at a 390px-wide viewport, ours beside the reference file. Judge, in order:
1. **Structure** — same elements, same order, nothing missing, nothing invented.
2. **Type** — family, size, weight, line-height, letter-spacing, case.
3. **Chrome** — border width, radius, shadow offset, and that shadows are hard (no blur).
4. **Colour** — exact token values, and that tangerine appears exactly once per screen as
   the forward action.
5. **Spacing** — gaps and padding within ~2px.

A screen is done when a reader shown both cannot say which is which without reading the URL.
