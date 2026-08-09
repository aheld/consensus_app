# Plan — global chrome, feedback, the swipe deck, and the dead-end sweep

Status: **in progress**, started 2026-08-08.
Design source: the re-imported `docs/design/create-and-share.dc.html` (2026-08-08) and its
per-frame extracts in `docs/design/screens/`. Read [docs/design/IMPORT-NOTES.md](../design/IMPORT-NOTES.md)
for what changed in that import and for the literal header/footer/swipe/how-it-works specs.

## The bar

**No user gets stuck or confused after taking an action.** Every flow is walked as a naive
first-time user, screenshotting each screen after each action. At every screen you must be
able to point at the obvious next step. A screen where you cannot is a failure, not a nitpick.

Corollary, and the reason this plan exists at all: **where the user's next action is off-site
— checking an inbox, opening a link in another app — a flash message is not enough.** A flash
is a transient strip over a screen that still looks like the one the user just acted on; it
reads as "nothing happened". Those become full-page success screens that state what happened,
what to do next, and what to do if it did not work. The magic-link flow is the canonical
failure: today the login form re-renders with a flash and the user simply sits there.

### What counts as confusion

Not just unclear wording. A screen can be pixel-perfect and perfectly worded and still leave
someone unsure what is going on. All seven of these are failures of the same bar:

1. **Unreadable affordance.** Something clickable that does not look clickable, or something
   inert that does. The Post-MVP `Bars` / `Movies` chips and the decorative share-target row are
   the existing cases; both are drawn dashed and greyed for exactly this reason. A new control
   inherits that obligation.
2. **Invisible state.** An action that registers server-side or client-side with nothing on
   screen changing. The ballot holds selections in `@approved` / `@veto_id` and sends nothing
   until submit — a voter must be able to see that their taps are held, and how many.
3. **Unpredictable outcome.** The user cannot tell what a control will do *before* pressing it.
   This app has three moments where the system does something permanent, and each one must say so
   in advance rather than after: **the ballot locks on submit and cannot be recast** (D-036),
   **the option pool freezes the moment voting opens** (D-037), and **the deadline closes voting
   by itself and picks a winner with no organizer action** (product invariant 3).
4. **No way back.** A screen with no escape, or an escape that lands somewhere surprising.
   Includes an action with no undo where the user had no reason to expect one.
5. **Ambiguous duplication.** Two controls that appear to do the same thing, so the user has to
   guess which is real — the two stacked back buttons the comp draws are exactly this.
6. **Unknown scope.** "How much more of this is there?" The wizard answers with `1/3`. A swipe
   deck that does not answer it is confusing however beautiful the cards are.
7. **Mode without a signal.** Where a screen has two views of the same data, the user must be able
   to tell which one they are in, how to get back, and that switching costs them nothing.

A critic that reports only wording problems has done a third of the job.

## The pieces

Each is built by one agent and judged by a separate critic with fresh context. The critic runs
the app, compares against the design frame, walks the flow, and names the single biggest
remaining gap. Loop until it passes.

| # | Piece | Touches |
|---|---|---|
| P1 | Global header + footer, applied to every screen | `components/layouts.ex`, `components/chrome.ex` (new), every LiveView's render, `app.css` |
| P2 | `/how-it-works` — design frame `00b`, linked from the footer | new LiveView, router |
| P3 | Feedback capture — footer faces → `00c` form → stored | migration, `Consensus.Feedback`, new LiveView, router |
| P4 | Feedback admin queue — mark read, private admin notes | new `AdminLive.Feedback`, router, `Consensus.Feedback` |
| P5 | Swipe deck (frame `1c-0`) as a toggle beside the sticker grid | `join_live/ballot.ex`, `group_live/review.ex`, new component, `hooks.js` |
| P6 | Dead-end sweep — full-page success screens | `user_live/*`, `join_live/*`, controllers, router |
| P7 | "Restaurant search coming soon." on `02 add options` | `group_live/options.ex` |
| P8 | Annotated walkthrough document | `docs/walkthrough.md` + screenshots |
| P9 | Ship to `main`, re-walk every flow on <https://dinner.isourthing.com/> | — |

## House style — what a builder must match

This repo has strong conventions. Breaking one is a regression even when the tests stay green.
Read [AGENTS.md](../../AGENTS.md) and the [CLAUDE.md](../../CLAUDE.md) invariants before writing
code; the `.claude/skills/{phoenix,elixir,sqlite,design-system}` skills are written against
*this* repo, not generic docs.

**Contexts.** Two authorization shapes already exist and the new code picks whichever fits:
`Consensus.Activities` takes `%Scope{}` first and proves ownership by binding the scope's
`user_id` and the row's `organizer_id` to the same variable *in the function head*;
`Consensus.Voting` is token-authorized because a voter has no account. Feedback's public write
path has **no** actor at all, so it looks like `Voting` — no scope argument. Its admin read and
annotate path is admin-only with no per-row owner, so it looks like `Accounts.set_admin/3`:
authorized by the router plus the `:require_admin` on_mount hook, and re-reading the actor
where a write is destructive.

**Every public, unauthenticated write rescues SQLite.** Copy the idiom verbatim from
`Consensus.Voting.create_participant/2`:

```elixir
rescue
  error in [Exqlite.Error, DBConnection.ConnectionError] ->
    {:error, {:database_busy, Exception.message(error)}}
end
```

**Free-text fields get no `maxlength`** (invariant 11 / D-026). The cap lives in the changeset
as `validate_length(:field, max: @max)`, the schema exposes it as a public zero-arg function
(`Activity.max_description_length/0` is the model), and the template renders a live grapheme
counter reading that same function. A browser counts UTF-16 code units and silently truncates a
paste; the changeset counts graphemes. Both the feedback message and any contact field inherit
this.

**Optional free text normalises blank to `nil`** — copy `Participant`'s `blank_to_nil/1`.

**Migrations** are generated with `mix ecto.gen.migration name_with_underscores`, never
hand-named. `timestamps(type: :utc_datetime)` on every table. Enums are plain `:string` columns
validated by `Ecto.Enum` in the schema — never a database `CHECK`, which SQLite will only accept
inside `CREATE TABLE`. A "not yet" state is a nullable timestamp column, the way
`participants.voted_at` is.

**Admin screens** go inside the existing `scope "/admin"` block and the existing
`live_session :require_admin` — a `live_session` name is declared once. Both guards stay: the
pipeline plugs reject the HTTP request, the on_mount hook rejects the websocket mount.

**Tests** use `Consensus.DataCase` / `ConsensusWeb.ConnCase` with `async: true` (which under
`max_cases: 1` buys isolation, not concurrency — invariant 15). Fixtures go through the real
context write path unless there is a chicken-and-egg problem, and say so in a comment when they
do not. `describe` blocks are named for the function-with-arity or for the invariant.

**Design.** The sticker system is `assets/css/app.css`'s `@theme` block plus
`ConsensusWeb.Sticker` and the restyled `ConsensusWeb.CoreComponents`. Do not invent a colour,
a radius or a shadow: 2px ink border, hard offset shadow with no blur, press-1px on anything
clickable, mint resting shadow on fields, and **tangerine appears exactly once per screen** as
the one forward action. `<.button>` and `<.input>` append `class` to their own classes rather
than replacing them.

## Rulings — where the comp and this repo disagree

**These are settled. They beat the frame.** The re-imported design is a set of static mockups and
it contradicts itself in places and contradicts this repo's own decisions in others. Each ruling
below says what to build and why; a critic who fails a screen for matching a ruling rather than the
frame is the one who is wrong.

1. **One back affordance per screen.** Frames `01` and `02` literally stack two back buttons — the
   global header's 29px `‹` *and* the wizard row's 34px `‹`. That is a mistake in the comp, and it
   fails this work's own acceptance bar: two controls that look like "back" and may go to different
   places is exactly the confusion we are removing. Build the global header's `‹` only.
   `Sticker.step_progress/1` keeps its 3-segment bar and its `1/3` counter and **loses its chevron**;
   the route it used to carry becomes the header's `back`. Same for `02b`'s `✕` — it is a close-to-
   parent, so it becomes the header's back control, and the row keeps only "Edit option" and
   "Remove".

2. **The public header is the `1c` treatment.** No `‹`, no `⋯`. The 18px icon plus the wordmark at
   700/12.5, then a yellow pill: `Create your own →`, `#FFD84D` (`--yellow`), 2px ink border, 99px
   radius, 4px 10px padding, 700/10.5, `shadow-sticker-2`, pressing 1px on hover with the fill going
   tangerine and the text white. Yellow, not tangerine, at rest — tangerine is reserved for the one
   forward action on the screen, which on the ballot is "Send my votes". This variant covers the
   whole `/join` tree. Frame `06` shows a `⋯` and no pill; `1c` shows the pill and no `⋯`. Unify on
   `1c` — the pill is the call to action the work asked for and `⋯` has nothing useful in it for a
   guest.

3. **Signed-out marketing pages** (`/`, `/how-it-works`, `/about`, `/privacy`) take the public
   header but swap the pill for a plain log-in link at 600/11.5, the way frame `00a` does. (Labelled `Sign in` in the frame and until D-048, which gave `/users/log-in` one name across all four controls that reach it: `Log in`.) On `/`
   the tangerine belongs to the splash's own forward action — labelled `Get started` when this
   was written and `Start something` since D-047, which is what `/how-it-works`, `/privacy` and
   the signed-in home already called the same destination — and a second yellow pill offering
   the same thing would just compete with it.

   **Amended after P1's second critic round: the marketing header keeps the back circle.** Ruling 2
   defines the public header as "no `‹`, no `⋯`" and this ruling inherits its shape, but the reason
   the `‹` is dropped on `/join` does not transfer: a guest arrives at a share link cold and has
   nowhere to go back *to*, whereas `/about`, `/privacy`, `/how-it-works` and `/feedback` are
   reached from **the footer of every screen in the app**, most often from the middle of the
   wizard. A standing page with no `‹` is a dead end — the exact failure this work exists to close
   — so all four render one, pointing at the `?return_to=` they were handed and falling back to `/`.
   `/` itself passes no `back` (it is the top of the app) and so still draws no circle. The `⋯` and
   the pill stay dropped on `:marketing` as written.

4. **The `⋯` menu is undrawn; here is what goes in it.** Signed in: the account's email as a muted
   monospace line, then Admin (only for an administrator), Settings, Log out. Signed out on an app
   screen: Log in, Start something (`Get started` until D-047 §4/D-048). It stays a `<details>` element rather than JS so it works before
   LiveView connects and closes on Escape by itself.

5. **No "Add your own" tile on the ballot, and `00b` must not promise one.** The sticker-grid frame
   draws an "Add your own" tile and the how-it-works copy implies friends can extend the pool after
   voting opens. The pool is frozen the moment the vote opens (invariant 16 / D-037) and the reason
   is data integrity, not workflow taste: `votes.activity_id` cascades, so an option added or removed
   under a cast ballot silently corrupts it. Do not build the tile. Where `00b`'s copy promises it,
   write copy that is true instead, and note the substitution.

6. **The veto counter is real; keep our veto control.** The sticker-grid frame shows a
   `1 VETO LEFT` counter but draws no control that spends it. Our ballot already has a per-card veto
   toggle. Keep the control, add the counter, and drive the counter from `group.veto_allowed` and the
   current selection.

7. **Undrawn states, decided here.** `00c` post-submit is a full-page thank-you, not a flash — that
   is this work's whole premise. End-of-deck on the swipe view is a summary of what the voter chose
   with the same "Send my votes" action the grid has, plus a way back into the deck to change a card.
   `/about` and `/privacy` are short, honest, real pages.

8. **The `/join` tree gets the footer's credits and nothing else, and an inert wordmark.** Added
   after P1's first critic round. Frame `4a` puts the feedback pair and the three standing links
   on every frame, and on the ballot that is five `navigate`s under "Send my votes". `@approved`
   and `@veto_id` live only in socket assigns until `Voting.cast_ballot/3` runs, and a guest has
   no account and no history of the group, so each of those links silently discards the ballot and
   strands them — the only route back is the original share link in whatever chat app they came
   from. That is the acceptance bar above failing on the exact screen the "guest drop-off under
   5%" metric is measured on. Same reasoning as ruling 2's `⋯`: the guest header and footer carry
   only what a guest can use. The `Create your own →` pill stays as the one labelled door out.
   Everywhere else the footer is the full frame, and each of its links carries `?return_to=` so a
   standing page comes back where it was tapped.

9. **The header's context slot is state, never the page's name.** Also from P1's critic round. The
   slot is the frame's `LIVE SESSION`: `STEP 2 OF 3`, `ADMIN`, `SHARE`. Where the screen's own
   `<.eyebrow>` or `<h1>` already says the word, the slot stays empty — `PRIVACY` above `Privacy`
   in the same uppercase DM Mono 110px apart reads as a duplicate, not as a label. Six screens
   shipped that way and were corrected.

## Token additions

Add to the `@theme` block in `assets/css/app.css`. Do not hardcode any of these hexes in a template.

| Token | Value | Used by |
|---|---|---|
| `--shadow-sticker-5` | `5px 5px 0 var(--color-ink)` | the swipe deck's top card, sticker-grid cards |
| `--color-faint-soft` | `#A9B7AE` | the footer's `·` link separators |
| `--color-violet-deep` | `#5A38DD` | swipe-deck approve control, hover |
| `--color-yellow-tint` | `#FFF6DC` | sticker-grid card hover fill |
| `--color-ink-35` | `rgba(23, 33, 28, .35)` | dashed rows, an unselected mood face |

## Decisions this work forces

- **D-032 said there is no global navigation bar.** This work reverses that: the re-imported
  design puts a wordmark header and a footer on every frame. D-032 must be edited in place —
  flip its status to superseded, keep its reasoning (the per-screen chrome differs, which is
  still true and is why the global header has to *coexist* with the wizard's back button and
  progress bar rather than replace them) — and a new entry recorded.
- **Feedback is a new public write endpoint reachable by anyone, signed out.** Record the
  spam/abuse posture actually chosen, whatever it is.
- **The swipe deck is a second view of the same ballot,** not a second ballot. It writes through
  the same `Consensus.Voting.cast_ballot/3` and inherits invariant 17 unchanged.

## Verification

`mix precommit` is necessary and not sufficient. Set `MIX_TEST_PARTITION` to something unique
whenever more than one agent may run the suite against this checkout — a shared
`consensus_test.db` hit by two runs produces real failures, not flakiness. CI additionally runs
`mix deps.get --check-locked`, `mix deps.unlock --check-unused`, `mix format --check-formatted`
and a docker job that boots the release image twice; the full local reproduction is in
`.claude/skills/elixir/SKILL.md`.

Local green is not done. P9 re-walks every flow on the deployed site.
