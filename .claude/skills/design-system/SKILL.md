---
name: design-system
description: The "sticker" visual design system for the Consensus app — the 2px ink border, hard offset shadow, radius, press and mint-focus rules behind the @theme tokens in assets/css/app.css, the ConsensusWeb.Sticker primitives (sticker_card, chip, pill, eyebrow, step_progress, position_badge, photo_frame) and the restyled ConsensusWeb.CoreComponents (button, input, header, table, list, flash). Use this when building or editing any screen under lib/consensus_web/live or lib/consensus_web/components, choosing a colour/shadow/radius/font, adding a button/chip/pill/card/badge, matching an imported design frame under docs/design/screens/, or wondering why a `btn`/`input`/`card`/`alert`/`badge` class renders as nothing (daisyUI was removed, D-028).
---

# The Consensus "sticker" design system

One hand-drawn light theme: a 2px ink outline and a hard, unblurred offset shadow on every
surface. No dark mode, no theme toggle (D-028) — don't add either back. No shared navbar: every
screen draws its own header (D-032) — a new screen owes its own way back in, `Layouts.app/1`
will not give it one. Source of truth is `docs/design/DESIGN-SPEC.md`, itself derived from the
imported design doc at `docs/design/create-and-share.dc.html` and the per-screen extracts in
`docs/design/screens/`. Tokens live in `assets/css/app.css`'s `@theme` block; the design-specific
primitives live in `ConsensusWeb.Sticker`; the generic building blocks are
`ConsensusWeb.CoreComponents`, restyled onto the same tokens.

**Where spec and code disagree, follow the code** — this skill describes what's actually shipped,
not what `DESIGN-SPEC.md` says in prose. The known gaps are called out inline below.

## When NOT to use this

Not for LiveView lifecycle, routing, `live_session`, PubSub, or HEEx syntax → **`phoenix`**
skill. Not for context functions, changesets, or scopes → **`elixir`** skill. Not for the
product's information architecture or which screens exist → `docs/plans/creation-flow.md`. This
skill stops at "how do I make it look right."

## The five rules

1. **2px solid ink border** — `border-2 border-ink` — on every card, chip, input, button,
   avatar, badge. Nothing in this system is borderless.
2. **Hard offset shadow, zero blur.** `box-shadow: Npx Npx 0 var(--color-ink)`, exposed as
   `shadow-sticker-2` / `-3` / `-4` / `-6`. N=6 is defined but **unused in `lib/`** — it was
   sized for the mockup's phone-frame chrome, which we deliberately don't render (see
   "What not to do"). In practice: N=4 for a primary button, N=3 for a card or photo frame,
   N=2 for a small chip/row/table row. Never add `blur` to a sticker shadow.
3. **Radius: `rounded-2xl` (16px) for cards, buttons, inputs, table/list rows and photo
   frames; `rounded-full` for chips, pills, avatars and the step-progress bar segments.**
   That is the *actual* ladder in code — one flat radius for every "surface," full-pill for
   every "selector." `DESIGN-SPEC.md` describes a wider per-screen ladder (15px on the splash
   rows, 14px on a pool row, 18–20px on a "large card"); none of that variation exists in
   `sticker_card/1` or `CoreComponents`, which hardcode `rounded-2xl` regardless of `depth`.
   Don't invent a one-off radius to chase a screen's stated number — match the components.
4. **Press on anything clickable, two steps, no fades or scales:**
   - `hover`: `translate(1px, 1px)` and the shadow drops one depth (`shadow-sticker-3` →
     `shadow-sticker-2`, etc.).
   - `active`: `translate(2px, 2px)` and the shadow disappears entirely.
   The pairing is `press-2` with `shadow-sticker-2`, `press-3` with `-3`, `press-4` with `-4`
   (`assets/css/app.css`). `disabled:` always drops shadow and opacity instead — see `button/1`.
5. **Text/select/textarea inputs carry a permanent mint shadow, not a focus-only one.**
   `shadow-field` (`3px 3px 0 var(--color-mint)`) is baked into every `<.input>` variant's
   default class unconditionally — there is no `:focus` selector anywhere in `app.css` or
   `core_components.ex`. `DESIGN-SPEC.md`'s five-rules section frames this as "input focus,"
   but the code (and every per-screen mockup description in the same file) treats mint as the
   field's resting shadow. Keyboard focus additionally gets the global 2px violet
   `:focus-visible` outline (`app.css` `@layer base`), which applies to every element in the
   app, not just inputs — the two effects stack.

## Tokens (`assets/css/app.css` `@theme`)

| Token | Utility | Hex | What it's *for* |
|---|---|---|---|
| `--color-ink` | `bg-ink` / `text-ink` / `border-ink` | `#17211C` | every border, primary text, every hard shadow |
| `--color-ink-soft` | `text-ink-soft` | `#3B4A42` | secondary body text (e.g. de-emphasised card titles) |
| `--color-muted` | `text-muted` | `#5E6D64` | labels, meta lines, captions, the `.eyebrow` colour |
| `--color-faint` | `text-faint` | `#8A968E` | disabled chip text, placeholder text |
| `--color-canvas` | `bg-canvas` | `#DDF0E2` | the page behind the app; `<body>`'s background |
| `--color-surface` | `bg-surface` | `#F7FBF8` | the app background *inside* a signed-in screen |
| `#FFFFFF` (no token) | `bg-white` | `#FFFFFF` | cards, inputs — plain Tailwind white, not a custom token |
| `--color-tangerine` | `bg-tangerine` / `text-tangerine` | `#FF6A2B` | **the one forward action per screen, and nothing else** — primary buttons, error flash, the "remove"/hover-tangerine accents. Two tangerine elements on one screen is a review finding. |
| `--color-violet` | `bg-violet` / `text-violet` | `#6B46F0` | votes, live/selected state, progress fill, the keyboard focus ring |
| `--color-violet-tint` | `bg-violet-tint` | `#F3EFFE` | hover fill on unselected outline chips |
| `--color-violet-soft` | `bg-violet-soft` | `#D6CCFB` | avatar/badge fills, one of the three `position_badge` cycle colours |
| `--color-mint` | `bg-mint` | `#B9EFC9` | success/"added" state, the permanent input-field shadow (rule 5), the `:mint` pill tone |
| `--color-mint-soft` | `bg-mint-soft` | `#C9E8D2` | photo-placeholder stripe alternate, the `:mint_soft` pill tone |
| `--color-yellow` | `bg-yellow` | `#FFD84D` | the secondary action (Add, Edit) — button hover fill, `:yellow` pill tone, the wizard back-button hover |
| `--color-yellow-soft` | `bg-yellow-soft` | `#FFE3A8` | badge fills, one of the three `position_badge` cycle colours |
| `--color-peach` | `bg-peach` | `#FFC2A3` | the avatar fill (`Layouts.avatar/1`) |
| `--color-ink-30` | `border-ink-30` | `rgba(23,33,28,.3)` | the de-emphasised "past"/muted card border (`sticker_card tone={:muted}`) |
| `--color-ink-12` | `bg-ink-12` | `rgba(23,33,28,.12)` | unfilled step-progress segments |
| `--font-sans` | `font-sans` | Instrument Sans | everything |
| `--font-mono` | `font-mono` | DM Mono | time, counts, urls, ALL-CAPS section labels (`.eyebrow`) |

Fonts load from Google Fonts in `root.html.heex` (`Instrument+Sans` + `DM+Mono`, `display=swap`)
— family names there must keep matching `--font-sans` / `--font-mono` here.

Shadow/utility tokens, not colours but named the same way: `shadow-sticker-2/3/4/6`,
`shadow-field` (mint, inputs), `shadow-chip` (mint, **defined but not yet consumed by any
component** — `.chip`'s selected state uses `shadow-sticker-2`, not `shadow-chip`), `shadow-sheet`
(the drop shadow for the not-yet-built share bottom sheet, `04`).

## Component index

### `ConsensusWeb.Sticker` (`lib/consensus_web/components/sticker.ex`)

| Component | Key attrs | Reach for this when |
|---|---|---|
| `sticker_card/1` | `tone: :white\|:mint\|:violet_tint\|:yellow\|:canvas\|:muted` (default `:white`), `depth: 2\|3\|4` (default 3), `interactive: boolean` | any bordered card, tinted callout, or list row that isn't a `<.table>`/`<.list>` row. `:muted` renders no shadow — it's the finished/cancelled "past" card only. |
| `chip/1` | `selected: boolean`, `disabled: boolean`, renders `<.link>` when `rest` has `navigate`/`href`/`patch`, else `<button type="button">` | a pill-shaped single choice — activity type, deadline time. `selected` changes fill **and** font-weight, never colour alone. Only one selected visual exists in code: ink border, violet fill, white bold text, `shadow-sticker-2`. |
| `pill/1` | `tone: :mint\|:yellow\|:violet\|:mint_soft` (default `:mint`) | a tiny status badge — `VOTING`, `YOUR TURN`, an attribution name. Not clickable. |
| `eyebrow/1` | none besides `class`/`rest` | the uppercase DM Mono section label above a field group (`SESSION TITLE`, `GROUP`). Thin wrapper over the `.eyebrow` CSS class. |
| `step_progress/1` | `total: integer`, `current: integer`, `back: string \| nil` | the wizard header — circular back button (omitted when `back` is `nil`) + N-segment bar + `current/total`. Already carries `role="progressbar"` and `aria-label` — don't re-add. |
| `position_badge/1` | `n: integer` | the numbered rounded-square badge on a pool row. Fill cycles mint → yellow-soft → violet-soft; purely decorative, the number is the real content. |
| `photo_frame/1` | `src: string \| nil`, `alt: string` (required), `height` (default `h-[150px]`), `inner_block` slot for overlay badges | any option/activity image. Falls back to the `.stripes-violet` diagonal placeholder on a nil `src` **or** a broken image (`onerror` swaps the class in). |

### `ConsensusWeb.CoreComponents` (`lib/consensus_web/components/core_components.ex`)

| Component | Key attrs | Reach for this when |
|---|---|---|
| `button/1` | `variant: "primary"\|"ink"\|nil` | `nil` (omitted) is the white secondary button (`shadow-sticker-2`, `press-2`, hovers yellow); `"primary"` is the one tangerine forward action (`shadow-sticker-4`, `press-4`); `"ink"` is the ink-filled style (Copy link) and has **no shadow and no press class at all** — an ink shadow on an ink fill wouldn't read, so rule 4 is deliberately skipped for this one variant. Renders `<.link>` when `rest` has `href`/`navigate`/`patch`, else `<button>`. Pass `type=` explicitly when you need form semantics. |
| `input/1` | `type:` (validated list), `field:`, `label:`, `errors:` | any form field. Label renders as an `.eyebrow`; errors render as a tangerine line with an exclamation icon under the field. `type="hidden"` and `type="checkbox"` skip the mint shadow (checkbox uses its own `checked:bg-mint` treatment instead). |
| `header/1` | `subtitle`/`actions` slots | a page's h1 + optional subtitle + right-aligned actions row. Not the wizard header — that's `step_progress/1`. |
| `table/1` | `rows:`, `col`/`action` slots | tabular data (currently only the admin user list). Wrapped in `overflow-x-auto` so a wide row scrolls itself, not the page. Rows are individually bordered/shadowed (`shadow-sticker-2`), not one bordered table. |
| `list/1` | `item` slot with `title:` | a vertical key/value list — each item its own `shadow-sticker-2` row. |
| `flash/1` | `kind: :info\|:error` | rendered through `Layouts.flash_group/1` only — never call it directly outside that. Mint for info, tangerine for error. |
| `icon/1` | `name:` (`hero-*`), `class:` | any icon. Heroicons only — never a `Heroicons` module, never an inline `<svg>`. |

### Shell (`ConsensusWeb.Layouts`, `lib/consensus_web/components/layouts.ex`)

Every screen opens with `<Layouts.app flash={@flash} current_scope={@current_scope}>` — it is
canvas + centred column + flash group **only** (D-032); pass `width={:wide}` for the desktop
console, `:phone` (max-width 440px) otherwise. `avatar/1` renders a peach circle with the user's
initial (`size:` in px, default 34). `account_menu/1` is a `<details>`-based dropdown a screen
renders itself when it wants one — it is not automatic, despite a stale comment in
`root.html.heex` implying otherwise.

### Four worked examples

**Primary action** — one tangerine button, the screen's single forward step:

```heex
<.button variant="primary" type="button" phx-click="publish">
  Get the share link
</.button>
```

**A field with label and error** — errors come free once the field belongs to a changeset-backed form:

```heex
<.input field={@form[:title]} type="text" label="Session title" placeholder="Friday dinner?" />
```

**A chip group** — deadline choice, one selected at a time, the deferred option disabled:

```heex
<div class="flex flex-wrap gap-2">
  <.chip
    :for={{label, value} <- @deadline_options}
    phx-click="select_deadline"
    phx-value-choice={value}
    selected={@form[:deadline_choice].value == to_string(value)}
  >
    {label}
  </.chip>
  <.chip disabled>Custom…</.chip>
</div>
```

**A pool row** — position badge, name, provenance line, a yellow edit pill and a tangerine-on-hover remove. No single component covers the whole row; compose it on `sticker_card` the way `table/1` and `list/1` compose their own rows:

```heex
<.sticker_card depth={2} class="flex items-center gap-3 px-3 py-2.5">
  <.position_badge n={index + 1} />
  <div class="min-w-0 flex-1">
    <p class="truncate text-sm font-bold text-ink">{activity.name}</p>
    <p class="font-mono text-[10.5px] text-muted">typed by you · no details yet</p>
  </div>
  <button
    type="button"
    phx-click="edit_activity"
    phx-value-id={activity.id}
    class="press-2 rounded-full border-2 border-ink bg-yellow px-3 py-1 text-[12px] font-semibold shadow-sticker-2"
  >
    ✎ Edit
  </button>
  <button
    type="button"
    phx-click="remove_activity"
    phx-value-id={activity.id}
    aria-label={"Remove " <> activity.name}
    class="text-muted hover:text-tangerine"
  >
    <.icon name="hero-x-mark" class="size-4" />
  </button>
</.sticker_card>
```

Note `DESIGN-SPEC.md`'s `02` screen calls the selected activity-type chip "ink-filled ... with a
mint shadow" — but `chip/1`'s only selected style is violet-filled with an ink shadow (the style
that *does* match the `01` deadline chips). There is no `tone=` escape hatch on `chip/1` today.
Until the component grows one, build a screen that needs the ink/mint variant by hand rather than
guessing at a prop that doesn't exist — same pattern as the pool row above.

## What not to do

- **No raw hex in HEEx.** The tokens are the contract — `bg-[#FF6A2B]` defeats the whole point
  of a shared palette. (The one sanctioned exception in the repo is the `<meta name="theme-color"
  content="#DDF0E2">` tag in `root.html.heex`, which sets mobile browser chrome and cannot take a
  Tailwind class.)
- **No daisyUI classes** — `btn`, `input`, `card`, `alert`, `menu`, `badge`, `tabs`, `toggle`,
  `fieldset`, `loading`. The plugin is gone (D-028); every one of these renders as an unstyled
  native element, so a screen using them looks *broken*, not merely off-brand. Grep for them
  before trusting an old snippet.
- **No `9:41` status bar, no `▮▮▮` battery glyph.** That's iOS mockup chrome baked into the
  design frames at `docs/design/screens/*.html`. We render in a real browser with its own
  chrome; building a fake one is out of scope (`DESIGN-SPEC.md` says so explicitly).
- **No blurred shadows, no opacity-fade hovers.** Every shadow in this system is
  `Npx Npx 0 <color>` with zero blur; every hover/press is a `translate`, never an opacity or
  scale transition. `disabled:opacity-[45%]` on `button/1` is the one sanctioned opacity fade,
  and it's for the disabled state, not hover.
- **No more than one tangerine element per screen.** It is reserved for the single forward
  action. A tangerine "Remove" link and a tangerine "Save" button on the same screen is two
  competing calls to action.
- **No second theme.** The app is deliberately single-theme light (D-028) — no dark-mode
  media query, no `data-theme` toggle, no guessed dark palette. If you find a `theme_toggle`
  reference anywhere, it's stale; `root.html.heex` no longer has the inline script that used to
  pair with it.

## Accessibility rules that are part of the design

- **Icon-only controls get `aria-label`.** The remove `✕` in the pool-row example above, the
  flash close button, the `step_progress` back link — all name themselves for a screen reader,
  never rely on the glyph alone.
- **Colour is never the only signal.** `chip/1`'s `selected` state changes font-weight (`font-
  medium` → `font-semibold`) and adds `shadow-sticker-2`, not just fill colour. Follow that
  pattern for any new selected/active state — weight or shape changes alongside colour.
- **Every `<button>` inside a `<.form>` gets an explicit `type`.** `button/1`'s docstring says
  so directly: omit `type=` and the browser default applies, which is `submit` inside a form —
  a "Remove" or "Edit" button with no `type="button"` will silently submit the enclosing form.
- **Live-updating regions need `aria-live` or a fully-spoken `aria-label`.** A bare `62/140`
  character counter or a `4h 12m` countdown is not speakable; either wrap it in
  `aria-live="polite"` (the pattern `Layouts.flash_group/1` and the home-page message already
  use — see `CLAUDE.md` invariant 11) or give it an `aria-label` that spells out the full
  phrase (`"62 of 140 characters"`, `"4 hours 12 minutes remaining"`).

## How to check your work

Serve the design reference and the running app side by side, then compare at a **390px-wide**
viewport — the design was drawn at 340×700 but our pages are responsive, so 390px is the
practical mobile-viewport width to judge against, not the mockup's exact frame size.

```bash
python3 -m http.server 4999 --directory docs/design    # or: the "design-ref" entry in .claude/launch.json
```

Start the app itself with the `consensus-dev` launch config (`mix phx.server`, port 4000).

| Route | Reference file |
|---|---|
| `/` signed out | `docs/design/screens/1b-0-00a-intro-start-page.html` |
| `/` signed in | `docs/design/screens/1b-1-00-home-start-page-1a.html` |
| `/groups/new` | `docs/design/screens/1a-0-01-setup.html` |
| `/groups/:id/options` | `docs/design/screens/1a-1-02-add-options-manual-mvp.html` |
| `/groups/:id/options/:activity_id` | `docs/design/screens/1a-2-02b-edit-an-option-full-screen.html` |
| `/groups/:id/review` | `docs/design/screens/1a-4-03-review-pool.html` |
| `/groups/:id/share` | `docs/design/screens/1a-5-04-share.html` |
| `/` at a wide viewport | `docs/design/screens/1b-2-desktop-organizer-console.html` (lowest priority — build after every phone screen) |

Full route ↔ module ↔ frame mapping, including what's explicitly out of scope for this pass
(the phase-2 discover screen, live results, the recipient's first view), is
`docs/plans/creation-flow.md`'s "What we are building" table — check there before assuming a
route exists.

Judge in this order, per `DESIGN-SPEC.md`'s own critic checklist — don't skip ahead to colour:

1. **Structure** — same elements, same order, nothing missing, nothing invented.
2. **Type** — family, size, weight, line-height, letter-spacing, case.
3. **Chrome** — border width, radius, shadow offset, and that shadows are hard (no blur).
4. **Colour** — exact token values, and tangerine appears exactly once as the forward action.
5. **Spacing** — gaps and padding within ~2px.

A screen is done when a reader shown both, side by side, can't say which is which without
reading the URL.
