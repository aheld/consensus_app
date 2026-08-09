# Plan — the voting loop (recipient join → ballot → live results → winner)

Status: **in progress — domain layer only.** This plan closes the gap CLAUDE.md names in its
opening paragraph: "voting, ranking, tallying, results, the recipient's `/join/:slug` screen
… do not exist in `lib/` yet." Place discovery (Yelp/Places) stays out — it is Post-MVP.

**What is built, as of 2026-08-08:** everything under *Domain* below — the migration, the two
schemas, `Consensus.Voting`, and its tests (including
`test/consensus/voting_concurrency_test.exs`, which casts real simultaneous ballots on a real
pool). Decisions recorded: D-034 (ballot concurrency and refusals), D-035 (unconditional
anonymity — the `03` toggle is now a stated rule), D-036 (the ballot is locked), D-037 (the
activity pool freezes when the vote opens).

**What is NOT built:** the entire *Web* section — no `/join/:slug`, `/join/:slug/enter`,
`/join/:slug/vote`, `/join/:slug/results` or `/groups/:id/results` route exists, and neither do
`JoinController`, `JoinLive.Entry`, `JoinLive.Ballot`, `JoinLive.Results` or
`GroupLive.Results`. The two-session live test and `scripts/e2e-voting-loop.md` do not exist
either. **`Consensus.Voting` is correct and unreachable**: nothing in the running application
calls it, so no organizer or guest can cast or see a vote yet. `GroupLive.Share` still carries a
`TODO` about the missing `/join/:slug` route. Do not describe the voting loop as delivered until
this paragraph can be deleted.

Read first: [CLAUDE.md](../../CLAUDE.md) engineering invariants 1, 11, 12, 13, 14, 15;
[docs/decisions.md](../decisions.md) D-029 (group lifecycle), D-030 (link preview),
D-031 (deadline offsets), D-032 (no navbar — since superseded by D-041, which put a global header and footer on every screen), D-033 (`max_cases: 1` +
`default_transaction_mode: :immediate`); [docs/design/DESIGN-SPEC.md](../design/DESIGN-SPEC.md).

## The design frames this builds

Three frames were marked **out of scope (voting side)** in `DESIGN-SPEC.md` and are now in
scope. A fourth — the ballot — was never extracted until now; `docs/design/extract_screens.py`
has been re-run and `docs/design/screens/` now holds the complete set.

| Frame | File | Becomes |
|---|---|---|
| `06` recipient's first view | `1a-8-06-recipient-s-first-view.html` | `GET /join/:slug` |
| ballot — "sticker grid · kept in play" | `1c-1-sticker-grid-kept-in-play.html` | `/join/:slug/vote` |
| `05` live results (organizer) | `1a-6-05-live-results-organizer.html` | `/groups/:id/results` |
| `05b` after anyone votes | `1a-7-05b-same-screen-after-anyone-votes.html` | `/join/:slug/results` |

~~`1c-0-swipe-deck-kept-in-play.html` is the *alternative* ballot treatment. Build the sticker
grid (`1c-1`); the swipe deck is not in scope.~~ **Reversed by D-044** — the deck ships as a
second *view* of the same ballot, opt-in behind a `Grid` / `Swipe` switch that appears on both,
with the grid still the default. The reasoning above still holds for *which is the lead*; only
"not in scope" is dead. (The frames were also renumbered: the deck is `1c-0`, the grid `1c-1`.
`1b-3` and `1b-4` now name entirely different screens — see the "`1b-4` filename trap" note in
`docs/design/IMPORT-NOTES.md`.)

`DESIGN-SPEC.md`'s "What matches the design means for a critic" section governs fidelity, and
its two global caveats still hold: **do not build the `9:41 ▮▮▮` iOS status bar**, and
`340×700` / `300×600` are mockup phone frames, not fixed app widths — match at a ~390px
viewport and stay sane wider.

### One deliberate deviation from the mockup

Frame `05b` draws a **"Change my ranking"** button. We do not build it. The requirement is
that a cast vote is **locked** — `Consensus.Voting.cast_ballot/3` refuses a second ballot at
the context level, not just in the UI. That footer slot instead renders the locked
confirmation. Recorded as **D-036**; do not "fix" its absence back in.

## Vocabulary

- **Participant** — one person in one group's vote. Either a **guest** (name typed, or blank
  for anonymous) or a **user** (signed-in account). `kind` records which, permanently: the
  brief requires "record which kind of voter each vote came from".
- **Ballot** — one participant's whole submission: a set of approved activities plus at most
  one veto. Submitted once, atomically.
- **Approval voting** is the MVP tally, and it is what the design draws: the ballot frame
  reads "Tap all you'd be happy with · Pick as many as you like". Ranked-choice (Borda / IRV)
  is explicitly Post-MVP under PRD scope discipline — **do not build it**, and do not let the
  word "ranking" in the `05b` mockup's copy imply otherwise.

## Domain — `Consensus.Voting`

New context. Does **not** live inside `Consensus.Activities`: that context is organizer-scoped
and takes `%Accounts.Scope{}` first, while every function here acts for a participant who
usually has no account at all.

### Migration — two tables

```
participants
  group_id      references activity_groups, on_delete: :delete_all, null: false
  display_name  string, null: true          # nil = anonymous; never blank-string
  kind          string, null: false          # "guest" | "user"
  user_id       references users, on_delete: :nilify_all, null: true
  token         string, null: false          # 32+ bytes url64, the browser's claim on this row
  voted_at      utc_datetime, null: true     # non-nil = ballot cast = LOCKED
  timestamps

  unique_index :token
  index [:group_id]
  unique_index [:group_id, :user_id]   # a signed-in user joins a group once (partial: user_id not null)

votes
  participant_id references participants, on_delete: :delete_all, null: false
  activity_id    references activities,   on_delete: :delete_all, null: false
  kind           string, null: false        # "approve" | "veto"
  timestamps

  unique_index [:participant_id, :activity_id]
  index [:activity_id]
```

`kind` on **both** tables is a plain string column read through `Ecto.Enum` — same shape as
`Group.status`. Per invariant 12 it is data; nothing may branch on `activity_type`.

SQLite notes (load the `sqlite` skill): no `ALTER COLUMN`, no adding a `NOT NULL` column to a
populated table, and name any `CHECK` constraint explicitly if you add one. Generate the
migration with `mix ecto.gen.migration` so the timestamp is right.

### Public API

```elixir
# identity
create_participant(%Group{}, attrs)          # attrs: :display_name, :kind, :user_id
get_participant_by_token(token)              # nil when unknown
get_participant_for_user(%Group{}, user_id)  # returning signed-in user resumes, never duplicates

# the ballot — the whole point
cast_ballot(%Participant{}, approved_activity_ids, veto_activity_id \\ nil)
  #=> {:ok, %Participant{voted_at: ~U[...]}}
  #=> {:error, :already_voted}      # participant.voted_at was already set
  #=> {:error, :not_open}           # group status is not :voting
  #=> {:error, :deadline_passed}
  #=> {:error, :unknown_activity}   # an id not in this group — do not trust the client
  #=> {:error, :empty_ballot}       # zero approvals and no veto

# reads
tally(%Group{})            #=> ordered [%{activity:, approvals:, vetoed?:, winner?:}]
participants(%Group{})     #=> for the avatar row: name/initial + voted? only
subscribe(group_id) / broadcast on cast
```

**`cast_ballot/3` is the correctness centre of this feature.** Requirements:

1. Everything inside one `Repo.transact/1` — the `voted_at` stamp and every vote row commit
   or fail together. Invariant 15: production runs `default_transaction_mode: :immediate`, so
   the write lock is taken at `BEGIN`; a second concurrent ballot queues rather than 500s.
2. Re-read the participant **inside** the transaction and re-check `voted_at`. The
   `%Participant{}` in hand came from a socket assign and may be stale — this is the same
   "don't trust the struct in hand" rule invariant 1 states for `Accounts.set_admin/3`. Two
   browser tabs double-submitting must produce exactly one ballot and one
   `{:error, :already_voted}`.
3. Validate every incoming activity id belongs to **this** group before writing. Ids arrive
   from the client.
4. Re-check group status and deadline inside the transaction too.
5. `rescue Exqlite.Error` into `{:error, {:database_busy, _}}`, the way
   `Accounts.set_admin/3` and `Activities.delete_activity/2` already do.

### Tally rules

- An activity with **one or more vetoes is eliminated** — struck through, no bar, `VETOED`
  pill. Design `03` states the rule: "Everyone gets one veto. Vetoed places drop out."
- Among survivors, rank by approval count descending, ties broken by `activity.position`
  ascending (the organizer's own order) so the result is deterministic and testable.
- The leader carries the tangerine `★`. Once the group is `:completed` the leader is the
  **winner**; before that it is just the leader.
- If `group.veto_allowed` is false, the ballot offers no veto and `cast_ballot/3` rejects one.
- Bar width is `approvals / max(1, highest_approval_count)`, as a percentage.
- **Anonymous mode shows totals only, never who approved what.** `tally/1` must not return
  per-participant choices at all — not "returns them and the template hides them". The avatar
  row showing *who has voted* is fine in both modes: participation is public, choices are secret.

## Web

### Routes

```elixir
# public, no account — new live_session :participant with an on_mount that resolves
# the participant token from the session
scope "/", ConsensusWeb do
  pipe_through :browser
  live "/join/:slug",         JoinLive.Entry,   :show     # frame 06
  post "/join/:slug/enter",   JoinController,   :enter    # sets the session, redirects
  live "/join/:slug/vote",    JoinLive.Ballot,  :show     # the sticker grid
  live "/join/:slug/results", JoinLive.Results, :show     # frame 05b
end

# organizer, inside the existing :require_authenticated_user live_session
live "/groups/:id/results", GroupLive.Results, :show      # frame 05
```

**Why a controller for `enter`.** A LiveView cannot write a session cookie. `JoinLive.Entry`
renders the name form; submitting it does a real form POST to `JoinController.enter/2`, which
creates the participant, puts `participant_token` into the Phoenix session keyed by group, and
redirects to the ballot. This is the only path that mints a participant.

Guard the whole `/join` tree on group status: `:draft` → "this vote isn't open yet";
`:completed`/`:cancelled` → send straight to results. Call
`Activities.maybe_complete_group/1` on mount (D-029's lazy, schedulerless completion) so a
deadline that has passed closes the group on the next page view rather than needing a scheduler.

### Screens

**`06` entry (`JoinLive.Entry`)** — organizer's initial + "<Name> invited you" pill, the group
title as the `h1`, the three DM Mono pills (`N SPOTS` · `CLOSES <chip>` · `~10 SEC`), the
voted-avatars row + "N friends already voted", then the name field with a `skip →` affordance,
the tangerine **Start voting**, and `NO APP · NO ACCOUNT · NO PASSWORD`. Blank name or `skip`
⇒ `display_name: nil`, `kind: "guest"`.

Signed-in visitors additionally get a one-line affordance to join **as their account**
(`kind: "user"`), which is how the brief's "or logging in as a known user" is satisfied.
Never *require* it — product invariant 1: voter friction is zero, and a guest must never see
a signup, a password, or an email field.

**Ballot (`JoinLive.Ballot`)** — the `1c-1` sticker grid. Two-column grid of tappable cards;
selected = `--mint` fill + the 21px ink circle `✓` top-right; unselected = white, hover
`#FFF6DC`. The 38px image strip is `Sticker.photo_frame` (invariant 14: it must degrade to the
striped placeholder when a third-party image 404s, never error). Footer: the DM Mono
`N PICKED · 1 VETO LEFT` line over the tangerine **Send my votes**. The design's dashed
"Add your own" tile is **not** in scope — friends adding options is a separate feature; omit
the tile rather than rendering it dead.

Veto: long-press is not discoverable on desktop. Give each card a small veto control and show
`1 VETO LEFT` / `0 VETOES LEFT` honestly. Hide it entirely when `group.veto_allowed` is false.

After submit, `push_navigate` to `/join/:slug/results`. Re-entering `/join/:slug/vote` once
`voted_at` is set must redirect to results — the lock is a route-level fact, not a disabled
button.

**Results (`GroupLive.Results` / `JoinLive.Results`)** — frames `05` / `05b`. One shared
function component, two callers. Violet header with the live countdown (`Consensus.Deadlines`
already does offset arithmetic — reuse it, do not add a time-zone database, D-031), `LIVE`
label, the avatar row (voted = filled + mint ring; waiting = dashed + `--faint`), the running
tally with violet bars, the `VETOED` treatment, and the anonymity caption.

Footer differs by viewer: organizer gets **Nudge N friends** + **Close now**
(`Activities.complete_group/2`); a participant gets the "Your votes are in." mint confirmation
card (this plan said "Your ranking is in"; D-045 corrected the string, because nothing in this
app ranks anything), a footer enumerated over every {status} × {participation} cell rather than
the muted "Only <Organizer> can nudge or close early" notice this plan called for (D-045 deleted
that sentence: there is no nudge path in `lib/`, and it rendered on `:completed` groups too,
telling a voter the organizer could "close early" a vote that had already closed), and — per D-036 — a locked
state where the mockup drew "Change my ranking".

Completed group ⇒ the winner is announced with the booking/paste-back CTA that product
invariant 5 requires.

### Live updates

`Consensus.Voting.subscribe/1` on the existing `"activity_group:<id>"` topic, broadcasting
`{:ballot_cast, group_id}` (never the ballot's contents — anonymity). Every open results
screen, organizer's and participants', re-tallies and re-renders. This is the brief's bar:
*the vote appears live in the organizer's already-open session.*

## Tests

- `test/consensus/voting_test.exs` — the context. Must include: double-submit produces one
  ballot + `{:error, :already_voted}`; an activity id from another group is rejected; a ballot
  after the deadline is rejected; veto elimination; tie-break by position; `tally/1` never
  returns per-participant choices.
- `test/consensus_web/live/join_live/{entry,ballot,results}_test.exs` and
  `group_live/results_test.exs`.
- **Two-session live test** — the ExUnit form of the acceptance bar. One `live/2` connection
  as the organizer on `/groups/:id/results`, a second as a guest through join → ballot →
  submit, then `assert render(organizer_view) =~ ...` showing the tally moved **without the
  organizer re-navigating**. Extend `test/consensus_web/journey_test.exs`.
- Suite stays `async: false`-safe: `max_cases: 1` is a correctness fix, not a knob (D-033).

## Acceptance — the browser script

`scripts/e2e-voting-loop.md` (a runnable, step-by-step script; the harness drives it with the
Browser tools) covering, in two live browser sessions:

1. Organizer signs in, creates a pool, **edits an activity mid-flow** and navigates back and
   forward without losing state.
2. Organizer **pastes a URL** and the preview image/name/description fill in.
3. Organizer publishes and copies the share link.
4. Second session opens that link cold, **enters a name**, votes.
5. The vote appears in the organizer's **already-open** session with no reload.
6. The guest's ballot is **locked** — returning to the ballot URL redirects to results.

## Out of scope

Yelp/Places discovery, ranked-choice, two-phase funnels, friends adding options to someone
else's pool, the swipe-deck ballot, saved friend groups, real push nudges (the Nudge button
may flash a confirmation without sending mail — there is no mail provider in production).
