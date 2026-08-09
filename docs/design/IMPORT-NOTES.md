# Design import notes — "Consensus · Create & Share", 2026-08-08

What is **new** in this import, at implementation detail. Written for a Phoenix/LiveView
builder who has this file plus `docs/design/screens/*.html` and **no access to the design
tool**. Every measurement below was read out of the frame HTML, not eyeballed.

Read [DESIGN-SPEC.md](DESIGN-SPEC.md) first for the token vocabulary (`--ink`, `--tangerine`,
`--violet`, `--mint`, `--yellow`, `--canvas`, `--surface`, `shadow-sticker-N`, the five
sticker-chrome rules). This file does not restate it — it records the delta.

> **DESIGN-SPEC.md is now partly stale and must be fixed separately.** Its "Looking at the
> target" table points at `1b-1-00-home-start-page-1a.html`, `1b-2-desktop-organizer-console.html`
> and `1b-3-…`/`1b-4-…` for the swipe deck and sticker grid. **All four of those filenames were
> deleted by this import** (see §2). It also predates the global header and footer entirely, so
> its per-screen sections describe screens with no chrome. Treat §3 and §4 of *this* file as
> superseding it for chrome.

---

## 1. Provenance

| | |
|---|---|
| Date imported | **2026-08-08** |
| Source | <https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af> |
| Source file | `Consensus - Create & Share.dc.html` → committed as `docs/design/create-and-share.dc.html` |
| Extractor | `python3 docs/design/extract_screens.py` (also modified in this import; +38/−0 lines) |
| Frames extracted | 25, into `docs/design/screens/` + a regenerated `screens/index.html` |
| Local server | `python3 -m http.server 4999 --directory docs/design` → <http://127.0.0.1:4999/screens/index.html> |

Every frame file is standalone, inline-styled, and loads Instrument Sans + DM Mono from Google
Fonts. Each references `./icon.svg`, which lives at `docs/design/icon.svg` — i.e. **one directory
above `screens/`, so the logo renders as a broken image in the extracted frames.** That is an
extraction artifact, not a design decision; the real asset is `priv/static/images/icon.svg`.

### Full frame inventory

| Section | Idx | Caption (design's own words) | Filename under `docs/design/screens/` |
|---|---|---|---|
| 4a | 0 | Pair in the footer, header drops to ⋯ · **recommended** | `4a-0-pair-in-the-footer-header-drops-to-recommended.html` |
| 4b | 0 | Pair in the header, beside ⋯ | `4b-0-pair-in-the-header-beside.html` |
| 2a | 0 | Tally — ranked bars with a settled check · **recommended, shipped as icon.svg** | `2a-0-tally-ranked-bars-with-a-settled-check-recommended-shipped-a.html` |
| 2b | 0 | Converge — three voices landing on one | `2b-0-converge-three-voices-landing-on-one.html` |
| 2c | 0 | Bubble — the chat, answered | `2c-0-bubble-the-chat-answered.html` |
| 1a | 0 | 01 · setup | `1a-0-01-setup.html` |
| 1a | 1 | 02 · add options (manual · MVP) | `1a-1-02-add-options-manual-mvp.html` |
| 1a | 2 | 02b · edit an option (full screen) | `1a-2-02b-edit-an-option-full-screen.html` |
| 1a | 3 | phase 2 · discover (behind "Restaurant") | `1a-3-phase-2-discover-behind-restaurant.html` |
| 1a | 4 | 03 · review pool | `1a-4-03-review-pool.html` |
| 1a | 5 | 04 · share | `1a-5-04-share.html` |
| 1a | 6 | 05 · live results (organizer) | `1a-6-05-live-results-organizer.html` |
| 1a | 7 | 05b · same screen, after anyone votes | `1a-7-05b-same-screen-after-anyone-votes.html` |
| 1a | 8 | 06 · recipient's first view | `1a-8-06-recipient-s-first-view.html` |
| 1b | 0 | 00a · intro (→ start page) | `1b-0-00a-intro-start-page.html` |
| 1b | 1 | **00b · how it works (from footer)** | `1b-1-00b-how-it-works-from-footer.html` |
| 1b | 2 | 00 · home (start page → 1a) | `1b-2-00-home-start-page-1a.html` |
| 1b | 3 | **00c · feedback form (from any header)** | `1b-3-00c-feedback-form-from-any-header.html` |
| 1b | 4 | Made with ❤️ in Philadelphia *(misleading — this is the 1280px desktop organizer console)* | `1b-4-made-with-in-philadelphia.html` |
| 1c | 0 | swipe deck · kept in play | `1c-0-swipe-deck-kept-in-play.html` |
| 1c | 1 | sticker grid · kept in play | `1c-1-sticker-grid-kept-in-play.html` |
| 1d | 0 | in-app preview + paste-ready copy | `1d-0-in-app-preview-paste-ready-copy.html` |
| 1d | 1 | QR handoff · for in-person groups | `1d-1-qr-handoff-for-in-person-groups.html` |
| 1e | 0 | conversational | `1e-0-conversational.html` |
| 1e | 1 | utility | `1e-1-utility.html` |

### Section captions in the source doc

The doc groups frames under five "turn" headings. These are the design's own words and they
carry intent:

- **1a** — "Lead direction — full mobile flow, stepped wizard"
- **1b** — "Home — mobile start page, and the desktop organizer console"
- **1c** — "Option-picking — ranked list is the lead, the other two stay in play"
- **1d** — "Share moment alternatives — native sheet lives in 1a"
- **1e** — "Copy tone on the join screen — cropped fragments, no chrome; the full screen with header + footer is 06 in 1a"
- **2** — app-icon exploration (2a is the shipped mark)
- **4** — header/footer chrome exploration (4a is ratified)

---

## 2. What changed vs the previous import

`git status` on `docs/design/` at import time: 1 modified source doc, 1 modified extractor,
**11 modified frames, 8 deleted frames, 15 untracked (new) frames**, plus a regenerated index.

### 2.1 Genuinely NEW frames (no prior counterpart, new content)

| Frame | What it is |
|---|---|
| `4a-0-…` | **The ratified global header + footer chrome.** See §3, §4. |
| `4b-0-…` | The rejected alternative (feedback faces in the header). Do not build. |
| `2a-0-…` | The app icon at 128/48/16px + a mono/dark variant. Already shipped as `icon.svg`. |
| `2b-0-…`, `2c-0-…` | Rejected icon directions. Do not build. |
| `1b-1-00b-how-it-works-from-footer.html` | **NEW SCREEN `00b`.** See §5. |
| `1b-3-00c-feedback-form-from-any-header.html` | **NEW SCREEN `00c`.** See §6. |

Sections **1c, 1d, 1e, 2a–2c, 4a–4b are new *groupings***. Of those, only 2a–2c and 4a–4b
contain frames that did not exist before; 1c/1d/1e are re-parents of frames that used to live
under 1b (below).

### 2.2 Frames that were RENUMBERED, not deleted

Nothing was removed from the design. The 8 `D` entries in `git status` are old filenames whose
content moved to a new section id:

| Old filename (deleted) | New filename | Content change |
|---|---|---|
| `1b-1-00-home-start-page-1a.html` | `1b-2-00-home-start-page-1a.html` | header replaced + footer added |
| `1b-2-desktop-organizer-console.html` | `1b-4-made-with-in-philadelphia.html` | logo lockup + Feedback nav item + footer block |
| `1b-3-swipe-deck-kept-in-play.html` | `1c-0-swipe-deck-kept-in-play.html` | public header + footer added |
| `1b-4-sticker-grid-kept-in-play.html` | `1c-1-sticker-grid-kept-in-play.html` | public header + footer added |
| `1b-5-in-app-preview-paste-ready-copy.html` | `1d-0-in-app-preview-paste-ready-copy.html` | header + heading 22→20px |
| `1b-6-qr-handoff-for-in-person-groups.html` | `1d-1-qr-handoff-for-in-person-groups.html` | header + heading 23→22px |
| `1b-7-conversational.html` | `1e-0-conversational.html` | **nothing but the `<title>`** |
| `1b-8-utility.html` | `1e-1-utility.html` | **nothing but the `<title>`** |

> **Note the `1b-4` filename trap.** The extractor names files from the caption, and the caption
> of the desktop console frame is `Made with ❤️ in Philadelphia`. The file is the **1280×790
> desktop organizer console**, unchanged in layout from the previous import apart from the logo
> lockup, a new `Feedback` sidebar item, and the footer block pinned to the bottom of the left rail.

### 2.3 Existing frames that CHANGED

**Every full-screen frame in the import now carries the global footer, and all but two carry the
global header.** That is the headline change. Per-frame beyond that:

| Frame | Change |
|---|---|
| `1a-0` 01 setup | Global header added **above** the existing wizard row. `h1` 31px → **29px**. Body gets `min-height:0; overflow-y:auto` and `gap` 20 → 18. Wizard row padding `8px 20px 14px` → `10px 20px 12px`. Footer added. |
| `1a-1` 02 add options | Global header added above the wizard row. Wizard row padding → `10px 20px 10px`. Footer added. `h1` unchanged at 29px. |
| `1a-2` 02b edit an option | Global header added **above** the existing `✕ / Edit option / Remove` row; that row keeps its own `border-bottom` and its padding tightens to `9px 20px 10px`. Footer added. |
| `1a-3` phase-2 discover | Global header added (slot reads `RESTAURANTS`). Search row padding → `9px 20px 10px`. Footer added. Still Post-MVP — do not build. |
| `1a-4` 03 review pool | Global header added. **No wizard row on this screen** — the global `‹` is the only back affordance. `h1` 27px → **25px**. Pool list `overflow:hidden` → `overflow-y:auto`. Footer added. |
| `1a-5` 04 share | Global header added **and dimmed with the page behind the sheet** (`filter:saturate(.5); opacity:.4` on the header div itself). Slot reads the session title, `DINNER FRIDAY?`. The bottom sheet is unchanged. No footer (the sheet covers it). |
| `1a-6` 05 live results | Global header added above the violet countdown band; band padding `12px 20px 16px` → `11px 20px 13px`, gap 6 → 5. Footer added. |
| `1a-7` 05b after voting | Same header. **"Your ranking is in" moved**: was a full-width mint sticker row in the body, now a mint pill inline in the violet band, beside "until votes close" (16px ink check circle + 700 11px label). Body becomes `overflow-y:auto`. The "Only Sarah can nudge or close early. The result lands here." bordered card is replaced by a plain centred 11px muted line reading **"Only Sarah can nudge or close early."** Footer added. |
| `1a-8` 06 recipient's first view | Global header added in its **public** form: logo lockup, slot `INVITED BY SARAH`, `⋯`, **no back button**. Body `overflow-y:auto`. Footer added. |
| `1b-0` 00a intro/splash | Header added in its **signed-out** form: logo lockup + a plain `Sign in` text link on the right; **no `‹`, no `⋯`, no slot**; header padding `6px 20px 8px` (wider than the 13px of every other header). Content gap 26 → 22. Footer added. |
| `1b-2` 00 home | Header **replaced**: the bare `<h1>Consensus</h1>` + avatar row became a bordered white bar (`border-bottom:2px solid #17211C; background:#fff; padding:8px 20px 10px; justify-content:space-between`) holding a logo lockup (24px icon + `700 18px` wordmark, `letter-spacing:-.02em`) and the 34px peach avatar. Footer added. |
| `1c-0`, `1c-1` | Public header added (logo + yellow `Create your own →` pill). `1c-1` heading 19px → **18px**; its grid gains `overflow-y:auto`. `1c-0` title row padding 14 → 12px top. Footer added. |
| `1d-0`, `1d-1` | Compact header added (27px controls, 18px icon, `12.5px` wordmark, `10px` slot reading `SHARE`). Headings shrink 2px and 1px respectively. **No footer** on either. |
| `1e-0`, `1e-1` | Unchanged. They are deliberately cropped copy fragments with no chrome — the section caption says so explicitly. |
| `1b-4` desktop console | Logo lockup now uses `icon.svg` (was a hand-drawn orange blob div) and the wordmark is capitalised `Consensus` (was lowercase `consensus`), `letter-spacing` −.03 → −.02em. New `Feedback` item in the left nav with a speech-bubble SVG. The footer block (faces + links + two mono lines) is pinned under the user chip in the left rail, above a `2px solid rgba(23,33,28,.18)` divider. |

### 2.4 What is NOT in this import

No frame for **About us** or **Privacy**, both of which the new footer links to. No frame for a
post-submit / thank-you state after the feedback form. No frame for an end-of-deck state on the
swipe ballot. No frame showing the `⋯` menu open.

---

## 3. The global header — exact spec

**Frame 4a is the ratified choice.** Its caption:

> "Either face opens the same form, pre-set to positive or negative — so one tap already tells you
> the sentiment. **Keeps the header to two controls** and puts the ask where people land when
> they're done."

4b's rejection reason, verbatim: *"Always in reach, but four controls crowd the bar and the session
label loses its room. The pair also reads as a rating of the current screen rather than the product."*

### 3.1 Literal transcription (4a)

Container:

```
display:flex; align-items:center; gap:9px;
padding:8px 13px 9px;
border-bottom:2px solid #17211C;   /* --ink */
background:#fff;                   /* --white */
```

Four children, left to right:

1. **Back control `‹`**
   `width:29px; height:29px; flex:none; border:2px solid #17211C; border-radius:50%;`
   `display:grid; place-items:center; font:600 15px/1 'Instrument Sans',sans-serif`
   No fill (transparent over the white bar). **No shadow.** Hover on the real screen frames:
   `background:#FFD84D` (`--yellow`). The glyph is U+2039 SINGLE LEFT-POINTING ANGLE QUOTATION
   MARK, not `<`.
2. **Logo lockup**
   `display:flex; align-items:center; gap:6px` wrapping
   `<img src="icon.svg" width="19" height="19">` + `<span style="font:700 13px 'Instrument Sans'">Consensus</span>`.
   In every *screen* frame this is an `<a>` to the home route with `text-decoration:none; color:#17211C`.
   In 4a it is a bare `<span>` — use the link form.
3. **Context slot** (see §3.4)
   `flex:1; text-align:right; font:500 10.5px 'DM Mono',monospace; color:#5E6D64` (`--muted`).
   Screen frames add `overflow:hidden; text-overflow:ellipsis; white-space:nowrap` — **keep that**,
   the slot holds a user-supplied session title on `04 share`.
4. **Overflow control `⋯`**
   `width:29px; height:29px; flex:none; border:2px solid #17211C; border-radius:50%;`
   `display:grid; place-items:center; font:700 13px/1 'Instrument Sans',sans-serif`
   Same no-fill/no-shadow/yellow-hover treatment as `‹`. The glyph is U+22EF MIDLINE HORIZONTAL
   ELLIPSIS (`⋯`), not `…` and not three periods.

Colours, both literal and by token:

| Literal | Token | Where |
|---|---|---|
| `#17211C` | `--ink` / `--color-ink` | border-bottom, both control borders, wordmark, glyphs |
| `#FFFFFF` | `--white` (`bg-white`) | header background |
| `#5E6D64` | `--muted` / `--color-muted` | context slot text |
| `#FFD84D` | `--yellow` / `--color-yellow` | `‹` and `⋯` hover fill |

**Padding caveat.** 4a uses `padding:8px 13px 9px`. Every real screen frame uses `6px 13px 8px`
because it sits directly under the mocked-up iOS status bar (`9:41 ▮▮▮`), which
[DESIGN-SPEC.md](DESIGN-SPEC.md) already says not to build. **Use 4a's `8px 13px 9px`.**

Height: 29px control + 8+9px padding + 2px border = **48px**.

### 3.2 Signed-in vs public — what the design actually shows

The design ships **five** distinct header variants. This table is exhaustive; every row was read
out of the frame.

| Screen(s) | Left | Slot | Right | Header padding |
|---|---|---|---|---|
| `00a` intro / splash, signed out (`1b-0`) | logo lockup 19px/13px | *(empty flex spacer)* | **`Sign in`** — `font:600 11.5px 'Instrument Sans'`, `#17211C`, hover `#FF6A2B` | `6px 20px 8px` |
| `00` home, signed in (`1b-2`) | logo lockup **24px icon / `700 18px` wordmark / `letter-spacing:-.02em`** | *(none — `justify-content:space-between`)* | 34px circular avatar, `2px` ink border, `#FFC2A3` fill (`--peach`), `700 13px` initial | `8px 20px 10px` |
| Wizard `01`/`02`/`02b`/`03`, phase-2, `04`, `05`, `05b` (organizer, signed in) | `‹` 29px | `NEW SESSION` / `RESTAURANTS` / `DINNER FRIDAY?` / `LIVE SESSION` | `⋯` 29px | `6px 13px 8px` |
| `00b` how it works | `‹` 29px | `HOW IT WORKS` | **no `⋯`** | `6px 13px 8px` |
| `00c` feedback | **`✕`** 29px (same box, glyph U+2715) | `FEEDBACK` | **no `⋯`** | `6px 13px 8px` |
| `06` recipient's first view (`1a-8`, **public**) | **no back control** | `INVITED BY SARAH` | `⋯` 29px | `6px 13px 8px` |
| Ballot, swipe deck and sticker grid (`1c-0`, `1c-1`, **public**) | logo lockup **18px icon / `700 12.5px` wordmark**, no back | *(none)* | **yellow pill `Create your own →`** | `8px 14px 9px`, `gap:8px` |
| `1d-0`/`1d-1` share alternates | `‹` **27px** | `SHARE` (`font:500 10px`) | `⋯` **27px** | `8px 13px 9px` |
| Desktop console (`1b-4`) | *(no top bar at all — a 206px left rail instead)* | — | — | — |

The **`Create your own →` pill** — this is the "brief call to action to make their own" the
requirement asks for, and the design does render it, on the two ballot frames:

```
background:#FFD84D;                 /* --yellow */
border:2px solid #17211C;           /* --ink */
border-radius:99px;
padding:4px 10px;
font:700 10.5px 'Instrument Sans',sans-serif;
color:#17211C;
text-decoration:none;
box-shadow:2px 2px 0 #17211C;       /* --shadow-sticker-2 */
margin-left:auto;
/* hover */ background:#FF6A2B; color:#fff;   /* --tangerine on white */
```

Label text, verbatim, including the arrow: **`Create your own →`** (U+2192).

**Where the design does not settle it, and what to build.** The public side is internally
inconsistent: `06` (the join landing) shows `⋯` and no CTA, while the two ballot frames show the
CTA and no `⋯`. There is **no frame at all** for a guest's results screen (`/join/:slug/results`).
Smallest thing consistent with the design:

- **Every unauthenticated route (`/join/:slug`, `/join/:slug/vote`, `/join/:slug/results`) uses the
  `1c` public header**: 18px icon + `700 12.5px` wordmark on the left, the `Create your own →`
  pill on the right, no `‹`, no `⋯`.
- Keep `06`'s context slot (`INVITED BY <organizer>`) **between** them when there is a meaningful
  string; the `1c` header has room because it has no left control. `flex:1` on the slot, pill after.
- **Drop `⋯` for guests.** Every plausible item behind it (see §3.5) is account-shaped, and the one
  item that is not — Feedback — lives in the footer, which guests get in full. This also removes
  the only public control the design leaves undefined.
- The **footer is identical** for guests and signed-in users. Nothing in it is gated.

### 3.3 Coexistence with per-screen chrome — answered from the frames

**The wizard's back button and progress bar are NOT in the global header. They are a separate row
directly below it, and that row has its own, larger, back button.** `1a-0` and `1a-1` literally
stack two `‹` controls:

```
[ global header ]  ‹(29px)  ◆Consensus   NEW SESSION   ⋯(29px)     ← border-bottom 2px ink
[ wizard row    ]  ‹(34px)  ▮▮▮▮ ▭▭▭▭ ▭▭▭▭            1/3         ← no border
[ h1 "What's the plan?" … ]
```

Wizard row, literally: `display:flex; align-items:center; gap:12px; padding:10px 20px 12px`
(`10px 20px 10px` on `02`). Its back control is `34×34`, `2px` ink, `border-radius:50%`,
`font:600 16px/1`. The progress bar is `display:flex; gap:5px; flex:1`, three segments of
`height:6px; border-radius:99px`, filled `#6B46F0` (`--violet`), unfilled `rgba(23,33,28,.12)`
(`--color-ink-12`). The step counter is `font:500 10px 'DM Mono'; color:#5E6D64`.

`03 review pool` (`1a-4`) has **no wizard row** — no second back, no progress bar. Its only back
affordance is the global header's `‹`. Step 3 of 3 is therefore never drawn as a progress bar.

**The option editor's `✕`** (`02b`, `1a-2`) is likewise in a **second row below the global header**,
not in it:

```
display:flex; align-items:center; justify-content:space-between; gap:12px;
padding:9px 20px 10px; border-bottom:2px solid #17211C;
  left group (gap:10px): ✕ 34×34 circle, 2px ink, font:600 16px/1, hover background:#FFD84D
                         + "Edit option"  font:700 15px 'Instrument Sans'
  right:                 "Remove"         font:600 12.5px, color:#FF6A2B, hover text-decoration:underline
```

So: **the global header is a fixed 48px band that never changes shape; per-screen chrome is always
an additional row beneath it.** The `04 share` frame confirms the header is part of the page and
not an overlay — when the share sheet dims the page, the header dims with it
(`filter:saturate(.5); opacity:.4` applied to the header div).

> **Flag for the builder:** two stacked back buttons on `01` and `02` is what the frames show, but
> it is almost certainly a mockup artifact of bolting a new global header onto existing screens.
> See §10, Q-A.

### 3.4 The `LIVE SESSION` slot

It is **not** a status indicator. It is a right-aligned, muted, uppercase **context label naming
what you are currently looking at**, and it is present on every header variant that has a left
control. Values observed across the import, verbatim:

| Value | Frame |
|---|---|
| `NEW SESSION` | `01` setup, `02` add options, `02b` edit option, `03` review pool |
| `RESTAURANTS` | phase-2 discover (Post-MVP) |
| `DINNER FRIDAY?` | `04` share — **the session title verbatim, uppercased by content not CSS** |
| `LIVE SESSION` | `05` live results, `05b` after voting, and 4a itself |
| `INVITED BY SARAH` | `06` recipient's first view |
| `HOW IT WORKS` | `00b` |
| `FEEDBACK` | `00c` |
| `SHARE` | `1d-0`, `1d-1` (at `font:500 10px`, not 10.5) |
| *(absent, empty spacer)* | `00a` splash, `00` home, `1c` ballot frames |

Type: `font:500 10.5px 'DM Mono',monospace; color:#5E6D64`. **There is no `text-transform` in the
markup** — every value is written in capitals in the source string. Decide whether to uppercase in
CSS (safer for a user-supplied title) and note that DM Mono's caps are the intended look either way.

Rules to implement:

- Draft group → `NEW SESSION`. Voting/completed group → `LIVE SESSION`, **or** the session title
  when the screen *is* that session's share/detail screen (`04` uses the title).
- Guest arriving from a link → `INVITED BY <organizer first name>`.
- Static pages → the page name.
- Home and splash → empty.
- **It must truncate, not wrap** (`overflow:hidden; text-overflow:ellipsis; white-space:nowrap`).
  A 140-grapheme session title in a 340px bar is a real case.

### 3.5 What `⋯` does — **the design does not settle this**

No frame renders an open menu, and 4a's caption says only that the pattern "keeps the header to two
controls". The only positive evidence is negative: `00b` and `00c` drop `⋯` entirely, which says the
menu is *session/account* scoped rather than universal, and the desktop console (`1b-4`) puts
**Feedback** in its left nav next to Sessions / Groups / History / Blacklist — so the desktop
equivalent of the menu contains at least those.

Smallest proposal consistent with the design and with what exists in `lib/`:

- Signed in, inside a session: **Rename session**, **Change deadline**, **Close voting early**
  (organizer only — the desktop console has a `Close voting early` button), **Copy share link**.
- Signed in, anywhere: **Account settings** (`/users/settings`), **Admin** (only when
  `@current_scope.user.is_admin`), **Log out**. This is the natural home for what
  `ConsensusWeb.Layouts.account_menu/1` used to render — that function is now deleted and its
  `<details>` implementation lives in `ConsensusWeb.Chrome.header/1`'s `⋯` (D-041).
- **Not** Feedback and **not** How it works — both are in the footer, on every screen, by design.
- Guests: no `⋯` at all (§3.2).

~~Record whichever set is chosen as a `D-0NN` before building it; it is a navigation decision, and
D-032 (no global navbar) is the entry it partially reverses.~~ **Done: D-041.** The `⋯` shipped
with the account-only set — email, Admin (administrators only), Settings, Log out signed in;
Log in and Get started signed out. The session-level actions above (rename, change deadline,
close early, copy link) stayed on the screens that own them and are **not** in the menu.

---

## 4. The global footer — exact spec

Identical markup in `1a-0`, `1a-4`, `1a-6`, `1a-7`, `1a-8`, `1b-0`, `1b-1`, `1b-2`, `1b-3`,
`1c-0`, `1c-1`. It is the single most repeated block in the import.

### 4.1 Container

```
position:relative; flex:none;
border-top:2px solid #17211C;      /* --ink */
background:#F7FBF8;                /* --surface */
padding:7px 14px 9px;
display:flex; flex-direction:column; align-items:center; gap:2px;
```

Four rows, top to bottom, all centred.

### 4.2 Row 1 — the feedback face pair

```
display:flex; align-items:center; gap:8px; padding-bottom:2px;
```

- **Label:** `How's this going?` — `font:600 10.5px 'Instrument Sans',sans-serif; color:#3B4A42`
  (`--ink-soft`). Note the apostrophe is U+2019 (`’`), not `'`.
- **Happy face** — `title="Good"`:
  ```
  width:26px; height:26px; border:2px solid #17211C; border-radius:50%;
  background:#B9EFC9;                /* --mint */
  display:grid; place-items:center; cursor:pointer;
  box-shadow:2px 2px 0 #17211C;      /* --shadow-sticker-2 */
  hover: transform:translate(1px,1px); box-shadow:1px 1px 0 #17211C;   /* .press-2 */
  ```
- **Sad face** — `title="Not good"`: identical box, `background:#FFC2A3` (`--peach`).

**The glyphs are inline SVG, not emoji and not text characters.** Exact markup, both 15×15 in every
screen frame:

```html
<!-- happy -->
<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#17211C"
     stroke-width="2.2" stroke-linecap="round">
  <circle cx="9"  cy="10" r="1.2" fill="#17211C" stroke="none"/>
  <circle cx="15" cy="10" r="1.2" fill="#17211C" stroke="none"/>
  <path d="M8 14.6c1 1.2 2.4 1.8 4 1.8s3-.6 4-1.8"/>
</svg>

<!-- sad — identical except the mouth path -->
  <path d="M8 16.4c1-1.2 2.4-1.8 4-1.8s3 .6 4 1.8"/>
```

The two mouths are exact reflections: the happy arc starts at y=14.6 and curves down-then-up; the
sad arc starts at y=16.4 and curves up-then-down. Do not substitute 🙂/🙁 — the design's line weight
(`stroke-width:2.2`) is what makes them read as part of the sticker system.

**Size discrepancy, resolve in favour of the screen frames.** 4a draws the pair at `28px` with a
`16px` SVG, `gap:9px`, label at `11px`, container padding `10px 14px 11px`. All eleven real screen
frames use `26px` / `15px` SVG / `gap:8px` / label `10.5px` / padding `7px 14px 9px`. **Build the
26px version.** 4a is an enlarged schematic of the pattern, not a screen.

**What a click does.** Per 4a's caption: *"Either face opens the same form, pre-set to positive or
negative — so one tap already tells you the sentiment."* Concretely:

- Happy → navigate to the feedback screen (`00c`) with mood **positive** pre-selected.
- Sad → same screen, mood **negative** pre-selected.
- The mood must be carried in the route so the screen is linkable and a page reload preserves it —
  e.g. `~p"/feedback?mood=positive"` / `~p"/feedback?mood=negative"`. `00c`'s own caption
  (**`From the footer — tap to switch`**) confirms the choice remains editable on the form, so the
  param is a default, not a lock.
- The faces are the **only** entry point the design gives for the feedback form on mobile. The
  desktop console adds a second: the `Feedback` item in the left nav.
- Neither face is a submit. Nothing is written until `Send feedback`.

### 4.3 Row 2 — the link row

```
display:flex; align-items:center; gap:8px;
font:600 10.5px 'Instrument Sans',sans-serif;
```

Exactly three links, in this order, separated by a middle dot:

`About us` · `How it works` · `Privacy`

- Link colour `#17211C` (`--ink`), `text-decoration:none`, hover `#FF6A2B` (`--tangerine`).
- Separator: a `<span>` containing U+00B7 `·` with `color:#A9B7AE` — **not an existing token, see §9.**
- `How it works` is the only one of the three that has a frame (`00b`, §5). `About us` and `Privacy`
  have none.

### 4.4 Row 3 — the cross-promo line

```
font:400 9.5px 'DM Mono',monospace; color:#5E6D64; text-align:center;
```
containing a single link:

`also check out marketfinder.us` → `https://marketfinder.us`, `color:#6B46F0` (`--violet`),
`text-decoration:none`, hover `#FF6A2B`.

Lowercase, no leading capital. This is an **outbound third-party link on every page of the app**,
including every guest-facing page. Ship it with `rel="noopener noreferrer"` and confirm it is
actually wanted before it goes to production — see §10, Q-F.

### 4.5 Row 4 — the signature

```
font:400 9.5px 'DM Mono',monospace; color:#5E6D64; text-align:center;
```
Text, verbatim: **`Made with ❤️ in Philadelphia`**

The heart is the **emoji** U+2764 U+FE0F (red heart + variation selector), rendered by the system
font inside a DM Mono line — that is why it appears in colour in the render. Not an SVG, not `&hearts;`.

### 4.6 Desktop variant (`1b-4`)

Same four rows, restacked into the 206px left rail beneath the user chip, above a
`border-top:2px solid rgba(23,33,28,.18); padding-top:11px` divider, `gap:5px`. Differences:
faces are **24px** with **14px** SVGs and **no box-shadow** (hover is `background:#FFD84D`, not a
press); the link row gets `flex-wrap:wrap; gap:4px 8px`; the two mono lines get `line-height:1.5`.

---

## 5. Screen `00b` — "How it works" — exact spec

File: `docs/design/screens/1b-1-00b-how-it-works-from-footer.html`.
Reached from the footer's `How it works` link, on any screen. Header: `‹` + logo + slot
`HOW IT WORKS`, **no `⋯`**. Background `#F7FBF8` (`--surface`).

Scroll body: `flex:1; min-height:0; overflow-y:auto; padding:18px 20px 12px; display:flex;
flex-direction:column; gap:18px`. At 700px tall the CTA is **below the fold** — the page is
designed to scroll.

### 5.1 Title block (`gap:7px`)

- `h1` — `font:700 30px/1.05 'Instrument Sans'; letter-spacing:-.03em`
  > **How it works**
- Sub — `font:400 13.5px/1.45; color:#3B4A42` (`--ink-soft`)
  > **Four steps, about two minutes end to end.**

### 5.2 The four steps

A vertical timeline, `display:flex; flex-direction:column; gap:0`. Each step is a
`display:flex; gap:13px` row whose left column is `flex:none` and whose right column is
`flex:1; padding-bottom:16px` (the last step has no `padding-bottom` and no connector).

**Numbered badge** (left column):
```
width:32px; height:32px; border:2px solid #17211C; border-radius:10px;
display:grid; place-items:center;
font:700 13px 'DM Mono',monospace;
box-shadow:2px 2px 0 #17211C;      /* --shadow-sticker-2 */
```
Fills cycle **`1` `#FFD84D` (`--yellow`) → `2` `#D6CCFB` (`--violet-soft`) → `3` `#FFC2A3`
(`--peach`) → `4` `#B9EFC9` (`--mint`)**. Note this is the `00a` splash's three-badge cycle with
mint appended, and that `border-radius` is **10px** here vs **9px** on `00a` — see §9.

**Connector** between badges 1–2, 2–3, 3–4 (not after 4):
```
width:2px; flex:1; margin:4px 0;
background:repeating-linear-gradient(#17211C 0 5px, transparent 5px 10px);
```
A vertical 5-on/5-off ink dash. It stretches, so the connector length is whatever the adjacent
copy block leaves.

**Step copy** — title `font:700 15px 'Instrument Sans'`, body
`font:400 12.5px/1.45; color:#5E6D64` (`--muted`), `margin-top:3px`. Verbatim, in order:

| # | Title | Body |
|---|---|---|
| 1 | **Add the options** | Type a name or paste a link. Anyone you invite can throw theirs in too. |
| 2 | **Share one link** | Drop it in the group chat. Nobody needs an app, an account, or a password to vote. |
| 3 | **Everyone ranks** | Drag your top three. Each person gets one veto for a hard no. |
| 4 | **The timer decides** | When it runs out the top-ranked place wins, and everyone sees it at the same moment. |

> **Copy accuracy warning.** Step 1 promises *"Anyone you invite can throw theirs in too"* and step 3
> promises *"Drag your top three"*. **Neither is true of the shipped app.** Friends adding options to
> someone else's pool is explicitly Post-MVP, the pool is frozen the moment voting opens
> (engineering invariant 16 / D-037), and the ballot is approval voting with veto elimination
> (D-034/D-036), not a drag-ranked top three. Do not ship this copy unedited — see §10, Q-D.

### 5.3 "Good to know" card

```
border:2px solid #17211C; border-radius:16px; background:#fff;
box-shadow:3px 3px 0 #17211C;      /* --shadow-sticker-3 */
padding:14px; display:flex; flex-direction:column; gap:8px;
```

- Eyebrow: `Good to know` — `font:600 11px 'DM Mono'; letter-spacing:.06em;
  text-transform:uppercase; color:#5E6D64`. This is exactly the existing `.eyebrow` class /
  `Sticker.eyebrow/1`. **The source string is title-case; the uppercase is CSS.**
- Three bullet rows, `display:flex; gap:9px; font:400 12.5px/1.4 'Instrument Sans'`. The bullet is a
  `<span>` holding U+00B7 `·` with `color:#6B46F0` (`--violet`) and `font-weight:700`. Verbatim:
  1. **Votes are anonymous. Everyone sees totals, never who picked what.**
  2. **Only the organizer can nudge or close voting early.**
  3. **Change your ranking any time before the timer ends.**

> Bullet 3 contradicts D-036 (the ballot is locked once submitted). Bullet 2's "nudge" has no
> implementation. Same warning as above.

### 5.4 CTA

Full-width anchor, the last child of the scroll body (`flex:none`):

```
background:#FF6A2B;                /* --tangerine — the one forward action on this screen */
color:#fff; text-decoration:none;
border:2px solid #17211C; border-radius:16px;
box-shadow:4px 4px 0 #17211C;      /* --shadow-sticker-4 */
padding:15px; text-align:center; display:block;
font:700 15.5px 'Instrument Sans',sans-serif;
hover: transform:translate(1px,1px); box-shadow:3px 3px 0 #17211C;   /* .press-4 */
```
Label, verbatim: **`Start something`** — no arrow, no `＋`. (The home screen's bar is
`Start something ＋`; this one is not.)

Destination: the frame's `href="#1b"` means "back to section 1b", i.e. **the start page**. For a
signed-in user that is `/groups/new`; for a signed-out visitor it must be the registration flow, the
same target as `00a`'s `Get started`.

The global footer sits below the scroll body.

---

## 6. Screen `00c` — "Feedback form" — exact spec

File: `docs/design/screens/1b-3-00c-feedback-form-from-any-header.html`.
Caption: *"00c · feedback form (from any header)"* — note the caption says *header*, but the
ratified 4a pattern reaches it from the **footer**. Treat "from anywhere" as the intent.

Header: **`✕`** (not `‹`) + logo + slot `FEEDBACK`, no `⋯`. Background `#F7FBF8` (`--surface`).
Scroll body `padding:18px 20px 10px; gap:16px`.

### 6.1 Title block (`gap:7px`)

- `h1` — `font:700 27px/1.06; letter-spacing:-.025em`, with an explicit `<br>`:
  > **Tell us how**
  > **to improve**
- Sub — `font:400 13px/1.45; color:#5E6D64` (`--muted`):
  > **Bugs, confusing steps, things you wish it did. We read every one.**

### 6.2 Mood row — how the chosen face is displayed

`display:flex; align-items:center; gap:9px`. Two 36px circles (larger than the footer's 26px) with a
20×20 SVG each — same two SVG paths as §4.2.

**Selected** (the frame shows *sad* selected, matching an arrival from the sad footer face):
```
width:36px; height:36px; border:2px solid #17211C; border-radius:50%;
background:#FFC2A3;                /* --peach for sad; --mint #B9EFC9 for happy */
box-shadow:2px 2px 0 #17211C;
```

**Unselected:**
```
width:36px; height:36px; border:2px solid rgba(23,33,28,.35); border-radius:50%;
background:#fff;
opacity:.55;
/* no box-shadow */
```

Then a caption, `font:400 11.5px 'Instrument Sans'; color:#5E6D64`, verbatim:
> **From the footer — tap to switch**

(em dash U+2014). So: the mood arrives pre-set from whichever face was tapped, both faces stay on
screen, and either is one tap away. Implement as a two-state radio group, not a toggle button.

### 6.3 Fields

All three share the field chrome:
```
border:2px solid #17211C; border-radius:14px; padding:12px 14px;
background:#fff;
box-shadow:3px 3px 0 #B9EFC9;      /* --shadow-field — mint at rest, per sticker rule 5 */
```
and all three sit in a `display:flex; flex-direction:column; gap:7px` group under an
`.eyebrow` label (`font:600 11px 'DM Mono'; letter-spacing:.06em; text-transform:uppercase;
color:#5E6D64`).

| Order | Label (verbatim) | Type | Value / placeholder in the frame | Helper (verbatim) |
|---|---|---|---|---|
| 1 | `Name` | single-line text, `font:500 14px` | **filled** value `Jordan`, colour `#17211C` | — |
| 2 | `Email` | single-line text | **placeholder** `you@example.com`, colour `#8A968E` (`--faint`) | `Only so we can reply. Leave it blank to stay anonymous.` — `font:400 11px; color:#5E6D64` |
| 3 | `What happened` | textarea, `font:400 13.5px/1.45`, `min-height:110px` | **placeholder** `I got stuck after adding my options…` (single U+2026 ellipsis), colour `#8A968E` | — |

Field 3's label row is `display:flex; align-items:baseline; justify-content:space-between` with a
counter on the right: `0/600`, `font:500 10px 'DM Mono'; color:#5E6D64`.

> **The counter is `0/600` while placeholder text is showing** — a mockup inconsistency; `0/600` is
> the empty state and is correct. Implement it under **engineering invariant 11 / D-026**: **no
> `maxlength` attribute**, the 600 cap enforced in the changeset, the counter counting graphemes
> the way `validate_length/3` does, and the counter turning `text-tangerine` past 600 so an
> over-length paste reads as a limit rather than a broken field.

The `Name` field being pre-filled with a value implies it is pre-populated from
`@current_scope.user.username` when signed in, and blank for a guest. Nothing in the design says
so; it is the only reading that makes `Jordan` appear without the user typing.

### 6.4 Context checkbox

```
display:flex; align-items:center; gap:9px;
border:2px dashed rgba(23,33,28,.35); border-radius:14px;
padding:10px 12px; background:#fff;
```
- Box: `width:20px; height:20px; flex:none; border:2px solid #17211C; border-radius:6px;
  background:#B9EFC9` (`--mint`), `display:grid; place-items:center`, glyph `✓` (U+2713)
  `font:700 11px 'Instrument Sans'`. **Rendered checked** — this is the default-on state.
- Label: `font:400 11.5px/1.35; color:#3B4A42` (`--ink-soft`), verbatim:
  > **Include the screen I was on (Dinner Friday? · voting)**

The parenthetical is dynamic: `(<session title> · <status>)`. When there is no session in context
(splash, home, `00b`), either drop the parenthetical or drop the row — the design does not say.
What it must attach when checked: the originating path and the group id/status, at minimum.

### 6.5 Action bar

Pinned above the global footer — **not** part of the scroll body:
```
flex:none; border-top:2px solid #17211C; background:#fff;
padding:12px 18px 16px; display:flex; gap:10px;
```
Note this bar's background is **`#fff`**, while the global footer beneath it is `#F7FBF8`. Two
stacked bars, two different fills, both with a 2px ink top border.

- **Cancel** — `border:2px solid #17211C; border-radius:15px; padding:13px 18px;
  font:700 14px; background:#fff;` **no shadow**; hover `background:#FFD84D` (`--yellow`).
  Not `flex:1` — it sizes to its content.
- **Send feedback** — `flex:1; background:#FF6A2B` (`--tangerine`); `color:#fff;
  border:2px solid #17211C; border-radius:15px; box-shadow:3px 3px 0 #17211C; padding:13px;
  text-align:center; font:700 14.5px`; hover `translate(1px,1px)` + `box-shadow:2px 2px 0`.

Labels verbatim: **`Cancel`**, **`Send feedback`**.

### 6.6 Post-submit state — **not in the design**

No frame. Smallest thing consistent with the rest of the system:

- Stay on the route, replace the scroll body with a centred confirmation using the same mint
  success language the app already uses: a `--mint` sticker card, an ink check badge, a `700 15px`
  line, and a single tangerine `Done` returning to the originating path (the same path the context
  checkbox captured).
- Or `push_navigate` back with a `put_flash(:info, …)`. Cheaper, and consistent with every other
  write in this app.
- Either way **the faces in the footer must not stay in a "pending" state** — they are stateless
  entry points, not a rating widget.
- Record the choice in `decisions.md`; storing feedback at all is a new table and a new context.

---

## 7. The swipe deck (`1c-0`) — exact spec

File: `docs/design/screens/1c-0-swipe-deck-kept-in-play.html`.
**The design's own caption for this option is, verbatim: `swipe deck · kept in play`.** Its section
heading is *"Option-picking — ranked list is the lead, the other two stay in play"* — i.e. this is
explicitly **not** the recommended ballot; it is retained as a live alternative. There is no prose
annotation on the frame beyond the caption. **Build §8 first.**

### 7.1 Frame

`width:300px; height:600px` (smaller than the 340×700 wizard frames), `background:#DDF0E2`
(`--canvas`), `border:2px solid #17211C`, `border-radius:30px`, `box-shadow:5px 5px 0 #17211C`
(**5px — not a current token, §9**), `overflow:hidden`, column, `position:relative`. No iOS status bar.

### 7.2 Public header

Per §3.2: `padding:8px 14px 9px; gap:8px`, `border-bottom:2px solid #17211C; background:#fff`;
`icon.svg` at 18×18, wordmark `font:700 12.5px`, then the yellow `Create your own →` pill at
`margin-left:auto`.

### 7.3 Session strip

```
padding:12px 18px 8px; display:flex; justify-content:space-between; align-items:center;
```
- Left: session title, `font:600 12px 'Instrument Sans'` — `Dinner Friday?`
- Right: **the progress indicator**, `font:500 11px 'DM Mono'; color:#3B4A42` — `2 / 5`
  (spaces around the slash are literal). This is the **only** progress affordance: no dots, no bar,
  no ring. It is a card counter, "you are on card 2 of 5".

### 7.4 Card stack geometry

Container: `flex:1; min-height:0; position:relative; margin:8px 18px 14px`. Three absolutely
positioned children, painted back to front:

| Layer | `inset` | `transform` | Border | Radius | Shadow |
|---|---|---|---|---|---|
| Back (3rd) | `14px 10px 0 10px` | `rotate(3.5deg)` | `2px solid #17211C` | `22px` | **none** |
| Middle (2nd) | `7px 5px 0 5px` | `rotate(-2deg)` | `2px solid #17211C` | `22px` | **none** |
| Top (1st) | `0` | none | `2px solid #17211C` | `22px` | `4px 4px 0 #17211C` (`--shadow-sticker-4`) |

All three `background:#fff`. Only the top card has `overflow:hidden` and content; the two behind are
empty white rectangles. Note the peel: each successive layer insets **down** (`top` 0 → 7 → 14) and
**in** (`left/right` 0 → 5 → 10) with `bottom:0`, so they peek out at the bottom, and the rotations
alternate sign (`0°`, `−2°`, `+3.5°`).

### 7.5 What is on the card

Top card is a column:

**Photo region** — `flex:1` (it takes all leftover height),
`background:repeating-linear-gradient(135deg,#C9E8D2 0 10px,#E6F5EA 10px 20px)`
(this is `--mint-soft` paired with a lighter mint; the existing `.stripes-mint` class uses the same
two colours at a 9px/18px pitch — the swipe frame uses **10px/20px**), `border-bottom:2px solid
#17211C`, `display:grid; place-items:center`. Centred in it, a mockup label chip:
`font:500 9.5px 'DM Mono'; background:#fff; border:1px solid #17211C; padding:3px 7px;
border-radius:4px` reading `restaurant photo`. **That chip is mockup scaffolding** — in the real
build this region is `Sticker.photo_frame/1` showing `activity.image_url`, degrading to the striped
placeholder (engineering invariant 14).

**Body** — `padding:14px 16px; display:flex; flex-direction:column; gap:7px`:

1. Name — `font:700 21px/1.1; letter-spacing:-.02em` → `Osteria Mozza`
2. Meta row — `display:flex; gap:6px; align-items:center; font:500 12px; color:#3B4A42`:
   - a cuisine pill: `background:#B9EFC9` (`--mint`), `border:1.5px solid #17211C`,
     `border-radius:99px`, `padding:2px 8px` → `Italian`
   - then three bare spans: `$$$`, `4.5 ★` (U+2605), `0.8 mi`
3. Detail line — `font:400 12px/1.4; color:#5E6D64` → `Open until 11pm Thursday · takes walk-ins`

> Price tier, star rating, distance and hours **do not exist in `Consensus.Activities.Activity`**
> and cannot until Places/Yelp lands (Post-MVP). Build the card with `name` + `description` +
> `image_url` and let the meta row collapse when empty.

### 7.6 Controls and gesture semantics

Row: `padding:16px 18px 20px; display:flex; align-items:center; justify-content:center; gap:14px`.
Three controls, left to right:

| Control | Geometry | Fill | Glyph | Hover |
|---|---|---|---|---|
| **Pass** | `58×58`, circle, `2px` ink, `box-shadow:3px 3px 0 #17211C` | `#fff` | `✕` U+2715, `font:600 20px 'Instrument Sans'` | `background:#FFE3A8` (`--yellow-soft`) |
| **Veto** | `44×44`, `border-radius:14px`, `2px` ink, `box-shadow:3px 3px 0 #17211C` | `#FF6A2B` (`--tangerine`), text `#fff` | `1×` (U+00D7), `font:600 11px 'DM Mono'` | `transform:translate(1px,1px)` |
| **Approve** | `58×58`, circle, `2px` ink, `box-shadow:3px 3px 0 #17211C` | `#6B46F0` (`--violet`), text `#fff` | `♥` U+2665, `font:600 22px 'Instrument Sans'` | `background:#5A38DD` — **not a token, §9** |

The veto sits in a `display:flex; flex-direction:column; align-items:center; gap:3px` wrapper with a
caption beneath it: `VETO`, `font:500 9px 'DM Mono'; color:#3B4A42`. It is **smaller and squarer**
than the two circles flanking it — deliberately not a peer of approve/pass.

**Gesture semantics are not stated anywhere in the frame.** There is no swipe annotation, no arrow,
no directional hint. What the frame *does* fix is the button set and its left-to-right order.
Proposal, consistent with that ordering and with the voting model in D-034/D-036:

- **Swipe right** = ♥ approve → adds the activity to the ballot's approval set.
- **Swipe left** = ✕ pass → advances without approving. **Not** a veto and not a downvote; the
  approval tally simply does not count it.
- **Veto is button-only, never a swipe.** Each voter gets exactly one (`1×`), it eliminates the
  option for everyone, and it is irreversible — far too destructive to attach to a flick. Its
  tangerine fill (the "one forward action" colour, used here on a *destructive* control) already
  signals that it is categorically different from the other two.
- Every gesture must have the button as an equal peer, not a fallback: the buttons are what the
  design draws, and they are the only accessible path.

### 7.7 End-of-deck state — **not in the design**

No frame shows card 5 of 5 dismissed. Proposal: when the deck empties, replace the stack + control
row with the sticker grid's summary block (§8.6) — the `N PICKED · N VETO LEFT` line and the
tangerine `Send my votes` button — so both ballot styles converge on the same submit. Nothing
should auto-submit; D-036 locks the ballot on submit and there is no recast.

---

## 8. The sticker grid (`1c-1`) — the current default ballot

File: `docs/design/screens/1c-1-sticker-grid-kept-in-play.html`. Caption, verbatim:
`sticker grid · kept in play`. **This is the shape the shipped `/join/:slug/vote` ballot should be
checked against.** Its content is unchanged from the previous import; what is new is the public
header, the global footer, `overflow-y:auto` on the grid, and an 18px (was 19px) heading.

**Frame:** `300×600`, `background:#DDF0E2` (`--canvas`), `2px` ink, `border-radius:30px`,
`box-shadow:5px 5px 0 #17211C`.

**Header:** the public one — logo 18px + wordmark `700 12.5px` + yellow `Create your own →` pill (§3.2).

**Prompt block** — `padding:12px 18px 8px`:
- `font:700 18px/1.1; letter-spacing:-.025em` → **`Tap all you'd be happy with`**
- `font:400 11.5px; color:#3B4A42; margin-top:4px` → **`Pick as many as you like.`**

(Approval voting, stated in the copy. Contrast with `00b` step 3's "Drag your top three".)

**Grid** — `flex:1; min-height:0; overflow-y:auto; padding:8px 16px;
display:grid; grid-template-columns:1fr 1fr; gap:10px; align-content:start`.

**Option card** — `border:2px solid #17211C; border-radius:16px; box-shadow:3px 3px 0 #17211C;
padding:11px; display:flex; flex-direction:column; gap:7px; min-height:96px; cursor:pointer`:

| | Unselected | Selected |
|---|---|---|
| Background | `#fff` | `#B9EFC9` (`--mint`) |
| Hover | `background:#FFF6DC` — **not a token, §9** | *(none declared)* |
| Check badge | absent | `position:absolute; top:8px; right:8px; width:21px; height:21px; border-radius:50%; background:#17211C; color:#fff; font:600 11px` glyph `✓` — **no border, no shadow** |
| Thumbnail stripes | one of four coloured pairs | `rgba(23,33,28,.14) 0 6px / transparent 6px 12px` — a **muted ink** pattern, not a pastel |

Thumbnail: `height:38px; border:1.5px solid #17211C; border-radius:9px` (note **1.5px**, not 2px).
Unselected stripe pairs observed, at a 6px/12px pitch:
`#FFDCC7`/`#FFEFE5` (peach) · `#FFE9AE`/`#FFF6DC` (yellow) · `#D9E6FB`/`#EDF3FE` (blue).
These are the same pairs as `.stripes-peach` / `.stripes-yellow` / `.stripes-blue` in
`assets/css/app.css`, at a **6px pitch instead of 9px** because the thumbnail is small.

Card text: name `font:700 13px/1.15`; meta `font:500 10.5px 'DM Mono'; color:#3B4A42;
margin-top:auto` → `$$$ · 4.5★` (again, data the app does not have).

**"Add your own" tile** — the last grid cell:
```
border:2px dashed #17211C; border-radius:16px; padding:11px; min-height:96px;
display:flex; flex-direction:column; align-items:center; justify-content:center; gap:6px;
cursor:pointer; hover background:#fff;
  28×28 square, 2px ink, border-radius:9px, glyph "+" font:600 15px
  label font:600 11px/1.2, centred, color:#3B4A42, literally "Add your<br>own"
```

> **Do not build this tile.** It lets a *voter* add an option to someone else's pool, which is
> Post-MVP by PRD scope discipline and is refused by `Consensus.Activities` with `{:error,
> :pool_locked}` once the group leaves `:draft` (engineering invariant 16 / D-037). Rendering it
> would be a control that always fails. See §10, Q-E.

**Summary + submit** — `padding:10px 16px 18px; display:flex; flex-direction:column; gap:8px`:
- `font:500 11px 'DM Mono'; color:#3B4A42; text-align:center` → **`2 PICKED · 1 VETO LEFT`**
  (uppercase in the source string, not CSS; the two counts are dynamic).
- **`Send my votes`** — `background:#FF6A2B` (`--tangerine`), `color:#fff`, `2px` ink,
  `border-radius:15px`, `box-shadow:4px 4px 0 #17211C`, `padding:14px`, `font:700 15px`,
  hover `translate(1px,1px)` + `3px` shadow.

Then the global footer.

**Gap the frame does not close:** there is **no veto affordance on a card**. The counter says
`1 VETO LEFT`, but nothing in the grid casts one. Long-press? A second tap cycling
neutral → approve → veto? A per-card `✕`? The design does not say. See §10, Q-C.

---

## 9. Token deltas

Read against the `@theme` block in `assets/css/app.css`. Everything below appears in a **new or
changed** frame and has **no** matching token.

### 9.1 Colours — missing tokens

| Literal | Where it is used | Proposed token | Notes |
|---|---|---|---|
| **`#A9B7AE`** | The `·` separators between `About us` / `How it works` / `Privacy` in the global footer, on **every screen** | **`--color-faint-soft`** | Lighter than `--faint` (`#8A968E`). Only ever a separator glyph. Alternative name: `--color-divider-ink`. |
| **`#5A38DD`** | `♥` approve button hover fill, swipe deck (`1c-0`) | **`--color-violet-deep`** | A darkened `--violet` (`#6B46F0`). The only hover in the import that darkens a fill instead of pressing into its shadow — it is a 58px circle with no room to press. |
| **`#FFF6DC`** | Unselected option-card hover fill, sticker grid (`1c-1`) | **`--color-yellow-tint`** | Parallels the existing `--violet-tint` (`#F3EFFE`). The value already exists *inside* `.stripes-yellow` as a gradient stop but is not a token, so a hover rule has to hardcode it today. |
| **`rgba(23,33,28,.35)`** | Dashed border on `00c`'s context checkbox row; border on the **unselected** mood face | **`--color-ink-35`** | `app.css` has `--color-ink-30` (.3) and `--color-ink-12` (.12). Either add `.35` or decide `.3` is close enough and change the frames' intent deliberately. Do not silently substitute. |
| **`rgba(23,33,28,.18)`** | Divider above the footer block in the desktop console's left rail | **`--color-ink-18`** | Desktop-only, lowest priority. |
| **`rgba(23,33,28,.2)`** | Border of the greyed `DRAFT` card in the desktop left rail | reuse `--color-ink-30`? | Desktop-only. |
| `#E6F5EA` | Light stop of the swipe card's mint stripe | none needed | Already a stop inside `.stripes-mint`. |
| `#F0F5F1` | 4a's `SCREEN CONTENT` placeholder stripe | **none — mockup only** | Do not tokenise. |
| `rgba(23,33,28,.62)` | The design doc's own annotation prose | **none — doc chrome** | Not part of the app. |

### 9.2 Shadows — one missing token

| Literal | Where | Proposed token |
|---|---|---|
| **`5px 5px 0 #17211C`** | Phone frames on `1c-0`, `1c-1`, `1d-1`; the card frames on `1e-0`, `1e-1`; the QR card on `1d-1` | **`--shadow-sticker-5`** |

`app.css` defines `--shadow-sticker-1/2/3/4/6`. **5 is missing and is now used by five frames.** Add
it, and add a matching `.press-5` (`translate(1px,1px)` + `--shadow-sticker-4`) if anything at that
depth becomes clickable. Everything else in the import is 1/2/3/4/6 — no other new depths.

### 9.3 Radii — new values

| Value | Where | Existing convention |
|---|---|---|
| **`10px`** | `00b`'s four numbered step badges | `00a`'s three numbered badges are **9px**. Same component, two radii. Pick one (recommend 10px, and change `00a`'s implementation) and note it. |
| **`6px`** | `00c`'s 20px context checkbox | New smallest radius in the system. |
| **`22px`** | Swipe-deck cards | Sits between the "20px large card" and "34px phone frame" rungs in DESIGN-SPEC's radius ladder. |
| **`30px`** | `1c-*` and `1d-1` phone frames | The 340×700 frames use 34px; the 300×600 frames use 30px. Both are mockup device bezels — **do not build either** (DESIGN-SPEC already says so). |
| `4px` | The `restaurant photo` mockup chip on the swipe card | Mockup scaffolding. |

### 9.4 Type — new sizes, no new families

Families are unchanged: Instrument Sans 400–700, DM Mono 400/500. New sizes introduced by the
chrome and the two new screens:

| Size / weight | Family | Where |
|---|---|---|
| `600 10.5px` | Instrument Sans | Footer link row; footer label `How's this going?` |
| `400 9.5px` | DM Mono | The footer's two centred lines (`marketfinder.us`, `Made with ❤️…`) |
| `500 10.5px` | DM Mono | Header context slot (`10px` on the `1d` compact variant) |
| `700 13px` / `700 12.5px` | Instrument Sans | Header wordmark, standard / compact public |
| `700 10.5px` | Instrument Sans | `Create your own →` pill |
| `700 30px/1.05` | Instrument Sans | `00b` `h1` |
| `700 27px/1.06` | Instrument Sans | `00c` `h1` |
| `700 15.5px` | Instrument Sans | `00b` CTA |
| `700 14.5px` | Instrument Sans | `00c` `Send feedback` |
| `500 9px` | DM Mono | Swipe deck `VETO` caption |
| `1.5px` border | — | Sticker-grid thumbnails, and the mint cuisine pill on the swipe card. The system's rule is 2px; 1.5px already existed on the home status pills and the `03` toggle knob. |

Also note two **shrinks** to existing headings, caused by the header eating 48px of vertical:
`01 setup` `h1` 31 → **29px**, `03 review pool` `h1` 27 → **25px**.

### 9.5 Not a token delta, but flag it

`00a`'s frame background is `#B9EFC9` (`--mint`), while DESIGN-SPEC.md §"`00a` intro" says
"Mint (`--canvas`) full-bleed" and `--canvas` is `#DDF0E2`. **The frame has always used `--mint`**
(it is unchanged by this import) — so this is a pre-existing spec/frame disagreement, not new.
Whichever the shipped splash uses, fix DESIGN-SPEC's wording, which conflates the two greens.

---

## 10. Open questions — things the frames genuinely do not settle

**Q-A · Two stacked back buttons.** `01 setup` and `02 add options` render a 29px `‹` in the global
header **and** a 34px `‹` in the wizard row directly beneath it. `03 review pool` has only the
global one. Is the wizard `‹` meant to be deleted (global header owns back, wizard row keeps only
the progress bar and `N/3`), or does the global `‹` mean "leave the wizard entirely" while the
wizard `‹` means "previous step"? The frames show both and explain neither. Deleting the wizard `‹`
and keeping the bar is the smaller change and reads cleanest; it also makes `01`/`02`/`03` consistent.

**Q-B · What is in `⋯`.** No frame opens it. §3.5 has a proposal. Needs a `D-0NN`.

**Q-C · How a veto is cast on the sticker grid.** The counter says `1 VETO LEFT` and no card
carries a veto control. The swipe deck has an explicit button; the grid has nothing.

**Q-D · `00b` copy contradicts the shipped product in three places.** "Anyone you invite can throw
theirs in too" (friends adding options is Post-MVP + invariant 16), "Drag your top three" (the
ballot is approval voting with veto elimination, D-034/D-036), "Change your ranking any time before
the timer ends" (the ballot locks on submit, D-036). Either the copy is rewritten to match, or these
are product commitments that need recording. **Do not ship the frame's copy verbatim.**

**Q-E · The "Add your own" tile on the ballot.** Same collision. It is drawn, it is Post-MVP, and
the context layer already refuses it. Cut it, or record a reversal of D-037.

**Q-F · `also check out marketfinder.us`.** An outbound third-party link in the footer of every
page, including guest-facing ones. Is this shipping? If yes: `rel="noopener noreferrer"`, and note
that it is the only external link in the app.

**Q-G · `About us` and `Privacy` have no frames.** The footer links to three pages and the design
delivers one. Both need copy and a route, or the links need removing from the footer.

**Q-H · Public header inconsistency.** `06` (join landing) shows `⋯` and no CTA pill; the two ballot
frames show the pill and no `⋯`; the signed-out splash shows a `Sign in` text link and neither.
§3.2 proposes unifying on the ballot treatment. Needs a decision.

**Q-I · Post-submit state for `00c`.** No frame. §6.6 proposes.

**Q-J · End-of-deck state for the swipe ballot.** No frame. §7.7 proposes.

**Q-K · Where feedback goes.** The form collects name, email, free text, mood and screen context.
There is no table, no context module, and no mail path for it. `Consensus.Accounts.UserNotifier`
is best-effort by invariant 9, so email alone would silently drop reports; a `feedback` table on the
SQLite volume is the obvious minimum, with the admin area as the read surface.

**Q-L · Does the header/footer chrome apply to `/users/*` and `/admin/*`?** Every frame in the
import is a product screen. Registration, login, settings and the admin user list are not drawn. The
footer is generic enough to apply everywhere; the header's context slot and `⋯` are not.

**Q-M · Where does the desktop console's chrome live?** `1b-4` has no top bar and folds the footer
into the left rail. At what viewport does the phone header/footer become the rail? DESIGN-SPEC
already ranks the console lowest priority, so this can wait — but the responsive breakpoint is
undefined.
