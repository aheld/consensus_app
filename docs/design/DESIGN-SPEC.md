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
| `00a` intro / splash | <http://localhost:4999/screens/1b-0-00a-intro-start-page.html> | in scope |
| `00` home | <http://localhost:4999/screens/1b-1-00-home-start-page-1a.html> | in scope |
| desktop organizer console | <http://localhost:4999/screens/1b-2-desktop-organizer-console.html> | in scope (lowest priority) |
| `01` setup | <http://localhost:4999/screens/1a-0-01-setup.html> | in scope |
| `02` add options | <http://localhost:4999/screens/1a-1-02-add-options-manual-mvp.html> | in scope |
| `02b` edit an option | <http://localhost:4999/screens/1a-2-02b-edit-an-option-full-screen.html> | in scope |
| `03` review pool | <http://localhost:4999/screens/1a-4-03-review-pool.html> | in scope |
| `04` share | <http://localhost:4999/screens/1a-5-04-share.html> | in scope |
| phase-2 discover | `1a-3-…` | **out of scope** (Post-MVP, PRD scope discipline) |
| `05` / `05b` live results | `1a-6-…`, `1a-7-…` | **out of scope** (voting side) |
| `06` recipient's first view | `1a-8-…` | **out of scope** (voting side) |

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
| `--yellow` | `#FFD84D` | secondary action (Add, Edit), hover fill |
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

Section labels are `DM Mono`, 11px, 600, `letter-spacing:.06em`, `uppercase`, `--muted`.

## Screens

### `00a` intro (public splash, signed out) — `/`
Mint (`--canvas`) full-bleed. Vertically centred stack: `CONSENSUS` eyebrow (DM Mono, 11px,
600, `letter-spacing:.1em`, uppercase) · `h1` 40px/1.02, 700, `letter-spacing:-.035em`,
three lines "Decide / together, / in minutes." · a 14.5px paragraph capped at 250px:
"Stop the group chat spiral. Put the options up, let everyone rank, get an answer."

Then three white sticker rows (3px shadow, 15px radius), each a numbered 30px rounded-square
badge (`1` yellow, `2` violet-soft, `3` peach; DM Mono 700 12px) + a 14px/700 title and an
11.5px muted line:
1. **Add anything** — Type a name or paste a link.
2. **Share one link** — No app, no account to vote.
3. **Everyone ranks** — Anonymous. One winner, no debate.

Footer: tangerine **Get started** button (full width, 16px pad, 16px radius, 4px shadow)
→ registration. Below it, centred 12.5px: `Have a link? Open it →`.

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
- **GROUP** — overlapping 30px avatars (−8px margin) with a `+N` bubble and a 12px muted
  caption. Saved friend groups are Post-MVP: show the organizer's own avatar and the caption
  "Just you so far · invite by link".
- Footer: tangerine **Pick a neighborhood →** in the design. Our step 2 is options, not
  location, so the button reads **Add the options →**.

### `02` add options — `/groups/:id/options`
Step 2 of 3 (two progress segments filled).

- `h1` "Add the options" 29px/1.08.
- **ACTIVITY TYPE** — horizontally scrolling chips. `Restaurant` is selected: ink-filled,
  white text, `2px 2px 0 var(--mint)`. `Bars` and `Movies` are dashed-border, `--faint`, and
  **not clickable** (Post-MVP). Helper: "Restaurants first. More types as we grow."
- **TYPE A NAME OR PASTE A LINK** — a text input (14px radius, mint shadow) and a yellow
  **Add** button (14px radius, `2px 2px 0 var(--ink)`).
  Pasting a URL fetches the page and fills image, title and description; all three stay
  editable. A typed non-URL just becomes a name with no details.
- The pool list, scrollable. Each row: 2px ink border, 14px radius, `2px 2px 0 var(--ink)`,
  a 24px rounded-square position badge (DM Mono 700 11px, fill cycles mint → yellow-soft →
  violet-soft), the name at 14px/700, a DM Mono 10.5px provenance line
  ("typed by you · no details yet" / "link · photo + description pulled"), a yellow `✎ Edit`
  pill and a muted `✕` that turns tangerine on hover.
- Sticky footer with a 2px ink top border: "N in the pool" 15px/700 over an 11px muted
  breakdown, and a tangerine **Review →**.

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

## What "matches the design" means for a critic

Compare at a 390px-wide viewport, ours beside the reference file. Judge, in order:
1. **Structure** — same elements, same order, nothing missing, nothing invented.
2. **Type** — family, size, weight, line-height, letter-spacing, case.
3. **Chrome** — border width, radius, shadow offset, and that shadows are hard (no blur).
4. **Colour** — exact token values, and that tangerine appears exactly once per screen as
   the forward action.
5. **Spacing** — gaps and padding within ~2px.

A screen is done when a reader shown both cannot say which is which without reading the URL.
