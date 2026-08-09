# Open Questions

Two kinds of open item, kept apart on purpose:

1. **Foundation gaps** (`F-` numbers, first section) — known limitations of code that has already
   shipped. Each was found by an adversarial review round and left open deliberately. Nothing here
   blocks the app from running, deploying, or meeting its acceptance criteria.
2. **Product questions** (`Q-` numbers, the rest) — decisions still needed before the voting engine
   is implemented.

Resolved items in either group move to [decisions.md](decisions.md) and get deleted from here.

The draft roadmap and the technical content extracted from the PRD answer several of these already;
they're listed because the answers are worth re-examining, not because the docs are silent. Prior
proposals: [technical-roadmap-v1-draft.md](technical-roadmap-v1-draft.md),
[prd-technical-extracts.md](prd-technical-extracts.md).

**Q-1, Q-2 and Q-3 have been deleted from this file, per the rule above.** All three were settled
together by [decisions.md](decisions.md) **D-003**, and the foundation described there is built:
Phoenix LiveView on the BEAM answers "one deploy target or two" (one), the framework's own
websocket answers "realtime transport" (no managed service, no polling), and `Phoenix.PubSub` in
the supervision tree plus SQLite answers "is Redis needed" (no — for neither fan-out nor caching).
The surviving numbers are unchanged, so this list still starts at Q-4.

---

## Foundation — known gaps in code that has already shipped

These are not undecided *product* questions like the Q-numbered items below. They are limitations of
the foundation as built, each one found by an adversarial review round, each one deliberately left
open rather than missed. They are recorded here because the next person to work on this repo needs
them, and a conversation is not a place to keep them.

Every one of these is a *known* gap with a *known* shape. None of them blocks the app from running,
deploying, or passing its acceptance criteria. Close them when the surrounding work makes them cheap,
not as a batch.

### F-1. A genuinely new migration never runs against a populated database

**Scoped down by an explicit call from the repo owner (2026-08-08): down migrations are not
maintained. On SQLite, the answer to a bad migration is a fresh database, not a rollback.** That
removes most of what this item used to worry about — "a `down` that is not a faithful inverse of its
`up`" is not a risk the project is carrying. Do not reintroduce reversibility as a requirement
without revisiting that decision.

What remains, narrower and still real: a new `up` migration is never exercised against a database
that has rows in it. ecto_sqlite3 emulates `ALTER COLUMN` and `ADD CONSTRAINT` by copy-and-swap, and
those rebuilds can fail against real data or a real foreign key while passing cleanly against the
empty database `mix test` and the CI smoke step both use. Migrating at boot is this app's *only*
migration path (D-009) on a single machine with no `release_command` fallback, so a migration that
fails there fails the boot.

The mitigation the project actually relies on is the one the owner named — recreate the volume — and
[TODO.md](../TODO.md) §7 documents that path. That is a defensible answer while there is no
production data. It stops being defensible the moment real accounts exist, and that is the trigger
for revisiting this, not a schedule.

**Consequence to act on, not yet done:** CI's `docker` job manufactures its "pending migration" by
rolling the newest one *down* and re-applying it. With downs unmaintained, that step now rehearses a
mechanism the project has declared unsupported — it produces the *appearance* of upgrade-path
coverage from a path nobody intends to use. Either manufacture the pending migration another way
(a throwaway migration file generated in the job) or relabel the step to say what it actually
proves: that the boot-time migrator runs and finds nothing to do on a populated database.

### F-2. Nothing has ever been deployed to Fly.io

Deployability is demonstrated, not performed: the image builds, boots on a mounted volume, migrates,
seeds, serves, survives a restart, and every `flyctl` command in [TODO.md](../TODO.md) was checked
against the real binary. But no Fly app exists, `flyctl` on this machine is not logged in, and the
first real deploy is still the first real deploy. The `[[http_service.checks]]` behaviour, the
volume's mount semantics, and the GitHub Actions → Fly hand-off are all reasoned from the official
guides rather than observed.

Related and more specific: `Consensus.BootCheck` has only ever been exercised against Docker named
volumes, which reproduce uid/gid semantics but not Fly's mount behaviour. And the snapshot-restore
procedure in TODO.md §7 (steps R1–R8) is documented, self-consistent and labelled untested — it has
never been executed against a live app, and it necessarily destroys and recreates the Machine
(D-019).

### F-3. The mail provider is configured but the secret may not be set

**Mostly closed by D-039.** Resend is now the provider: `config/runtime.exs` selects
`Swoosh.Adapters.Resend` for `:prod` whenever `RESEND_API_KEY` is set, and falls back to
`Swoosh.Adapters.Logger` — with a boot warning — when it is not.

What remains open is operational, not a code gap, and it has two halves that fail differently:

1. **The secret must actually be set** (`fly secrets set RESEND_API_KEY=re_...`). Until it is, the
   fallback is in force and nothing is delivered. `fly secrets list` is the only reliable check —
   do not infer it from the config file, which is conditional by design.
2. **`MAIL_FROM` must be on a domain verified in the Resend dashboard.** This one fails *after* the
   key is set and looks different: the app is configured correctly, the boot warning is gone, and
   every send is rejected at the provider. Unset, the sender defaults to `onboarding@resend.dev`,
   which Resend only delivers to the account owner's own address — so a "working" first test can be
   misleading about whether anyone else will receive anything.

Registration takes a password and signs the new account in immediately, so nobody is ever *blocked*,
and `Accounts.delete_user/2` from `/admin/users` remains the account-recovery lever. Note what is
still gated on delivery: the credential pre-stuffing defence in D-017 only fires when the real owner
clicks a link they can only receive by email, so it stays a correct mechanism with no channel until
both halves above are done.

### F-4. Two test guards weaken silently in environments unlike this one

Worth knowing before trusting a green run from somewhere else:

- The permission assertions in [test/consensus/boot_check_test.exs](../test/consensus/boot_check_test.exs)
  are wrapped in `if append_denied?(...)` / `if write_denied?(...)` guards, because `chmod` does not
  restrain uid 0. Run the suite **as root** — which some CI containers do — and those tests pass
  *vacuously* rather than failing. They were verified to fail on the intended mutants as a non-root
  user only.
- The 375px layout measurements behind the navbar fix were taken in a same-origin iframe, not a
  real phone-width browser window, because the automation could not resize the window. Width-driven
  layout and media queries are equivalent there and the numbers matched, but the iframe does not
  model device-pixel-ratio, mobile user-agent behaviour, or an overlay scrollbar stealing width.
  One confirming look on a real phone would close this.

Separately, `aria-live="polite"` on `<p id="home-message">` was verified as an attribute in the DOM,
not by listening to a screen reader.

### F-6. Found by the final review round and deliberately not fixed

The last round of adversarial review ended by owner decision with these open. Each is real, each was
reproduced, none blocks anything. Listed roughly by value.

- **The sudo windows are inverted relative to risk.** `Consensus.Accounts.@sudo_mode_minutes` is
  **20** and gates `set_admin/3` and `delete_user/2`; `UserAuth.on_mount(:require_sudo_mode, ...)`
  passes **-10** and gates `/users/settings`. So the strictly more dangerous action — minting an
  administrator — has the *looser* freshness requirement. D-021 records the two windows as
  deliberate, which they are, but does not confront the inversion. Deciding this properly means
  picking one window or justifying two; it is a behaviour change with test fallout, which is why it
  was left.
- **`Consensus.BootCheck` reports a read-only mount as a permission problem.** Booting against a
  read-only `/data` produces `Cannot write the SQLite database (:erofs).` followed by
  `refused : /data — directory, uid 65534:gid 0, mode 750` — correct ownership, correct mode — and
  then recommends a `chown` that cannot help. `:erofs`, `:enospc` and `:eacces` want different
  sentences.
- **A preflight crash writes `erl_crash.dump` into `/app` inside the container.** On Fly a raising
  preflight is a restart loop, so that is one multi-megabyte dump per restart, on a machine whose
  disk problem may be what is causing the loop. Set `ERL_CRASH_DUMP_SECONDS=0` in the release
  environment, or point the dump somewhere bounded.
- **CI never issues a single HTML request against the release image.** `/health` deliberately
  bypasses the `:browser` pipeline, the session, the layout and the digested-asset lookup, and the
  websocket assertion renders no HTML — so `cache_static_manifest` and `Plug.Static` are exercised by
  nothing in the pipeline. A broken asset digest in a release would ship green. One `curl -f /` with
  an assertion on the served CSS path would close it.
- **After a successful pre-stuffing reclaim the account keeps the attacker's chosen username.**
  Nothing tells the victim to change it. `/users/settings` can, but the flow does not mention it.
- **`Consensus.Seeds` prints `http://localhost:4000/...` with the port hardcoded**, while the
  endpoint's port comes from `PORT`. Cosmetic, dev-only, wrong whenever `PORT` is set.
- **The `test` job pins Elixir 1.20.3 / OTP 29.0.5 with a comment saying to keep it in step with the
  Dockerfile's `ELIXIR_VERSION` / `OTP_VERSION`, and nothing enforces it.** Self-correcting in
  practice, since drift that matters breaks `docker build`.
- **`/admin/dashboard/applications?info=consensus` returns 500** — `phoenix_live_dashboard` 0.8.7,
  not this repo's code, and not reachable from any link the app renders. Upstream.
- Two documentation nits: `aria-live="polite"` on `<p id="home-message">` is test-guarded and
  explained in CLAUDE.md but has no `decisions.md` entry; and D-024 quotes the navbar `<ul>` class
  string without its trailing `px-1`.

### F-5. Deferred by explicit decision, listed so they are not rediscovered as bugs

- **The admin sudo window is computed once, at mount.** A long-open `/admin/users` renders enabled
  buttons that bounce to the log-in page. Accepted by the repo owner; see D-021, which also records
  that the honest fix is refreshing the assign rather than widening the window.
- **No `user_audit_events` table.** The `[audit]` Logger line is the floor, not the ceiling —
  durable audit is a schema, a retention policy and a migration, and it belongs beside the
  voting-engine schema decisions rather than ahead of them (D-021).
- **`Content.update_home_page/2` carries no sudo check and no audit line**, deliberately: editing
  prose is not exercising authority (D-021). If the home page ever becomes something an attacker
  would want to control, revisit that.

---

## Blocking — decide before finishing the voting engine

The domain layer (`Consensus.Voting`, D-034 through D-037) is built; the `/join` web layer is not.
Some of what follows is therefore now half-answered, and says so in place.

### Q-4. Guest identity — the token is settled, the transport is not

Milestone 1.1 puts guest sessions in `localStorage`. Two problems:

1. **In-app webviews.** iMessage and WhatsApp open links in their own webview, whose storage is
   separate from (and less durable than) the user's real browser. A voter who reopens the link
   from the chat thread can land in a fresh storage context and appear as a new participant.
2. **Integrity.** "One vote per voter" and "one veto per voter" are unenforceable if identity
   lives entirely client-side. Anyone can clear storage and vote again.

**Half settled.** The storage half is decided and built: `participants.token` is 32 bytes of
`:crypto.strong_rand_bytes/1`, minted server-side by `Consensus.Voting.create_participant/2`,
never castable from client input, and the *only* way to turn a browser back into a participant
row (`get_participant_by_token/1`). "One vote per voter" is enforced by `participants.voted_at`
and a conditional `UPDATE` (D-036), and "one veto per voter" by the ballot being submitted whole,
once. `localStorage` is not used anywhere.

**Still open:** the transport. The token has to reach the browser somehow, and the plan puts it in
the Phoenix session via `JoinController.enter/2` — but that controller, and the whole `/join` tree,
is not built yet, so nothing has been decided about cookie attributes, what happens in an iMessage
webview that drops the cookie, or whether a returning voter with no cookie may re-claim their row
at all. Decide that with the web layer, not before.

### Q-5. Do booking deep-links actually exist?

Phase 1 promises a "Book Now deep-link router pointing to OpenTable and Resy checkout endpoints."
Neither platform offers public deep-link/booking APIs at hobby tier. The redirect-gateway
mitigation (Risk #3) is the right *shape*, but the premise needs a spike first. Realistic
fallbacks: restaurant's own site, a Google Maps place link, or a platform search URL prefilled
with name + party size.

The PRD's original phase diagram listed this as a Phase 1 technical spike, ahead of any build work
— the more honest ordering. Run the spike before committing "Instant Booking Action" to the MVP as
specified. (See [prd-technical-extracts.md](prd-technical-extracts.md) § From §8.)

### Q-6. Places/Yelp: which provider, and does caching survive their terms?

- **Google Places** moved to per-SKU pricing; a naive search-as-you-type loop gets expensive fast.
- **Yelp Fusion** access terms have tightened; confirm current availability and whether our use
  qualifies.
- Google Maps Platform terms restrict how long non-ID place content may be cached. The roadmap's
  headline cost mitigation *is* a 24-hour cache — verify that's permitted before it becomes
  load-bearing. Place IDs and our own derived data are the safer things to persist.

Also unstated: **what's the monthly infra + API budget?** It no longer decides the stack — D-003
settled that, and one Fly machine with one volume is the whole hosting bill — but it is still the
number that decides how much third-party search this app can afford, and therefore this question.

### Q-7. How does anyone learn the winner?

PRD persona relief for Rachel: "receives an automatic winner notification." With no accounts, no
email, and no push, we have no delivery channel. Web push on iOS requires an installed PWA — which
contradicts the zero-friction premise for guests.

Realistic MVP: the organizer gets a generated summary string to paste into the group chat (already
in the PRD), and the session link itself becomes the results page. Optional phone/email capture is
friction we said we wouldn't add. Needs an explicit call.

---

## Spec gaps — the two docs disagree or omit something

### Q-8. Veto semantics — only the floor is still open

Four of the five bullets are answered by the shipped engine and recorded in
[decisions.md](decisions.md):

- *What happens to votes already cast for a now-vetoed option?* Nothing is deleted. `tally/1`
  splits the pool into survivors and eliminated; a vetoed row keeps its approval count and is
  rendered struck through with `bar_percent: 0`.
- *Can a veto be withdrawn?* No — the whole ballot is locked once cast (**D-036**).
- *Is the veto anonymous?* Yes, like every other mark: the context cannot produce per-participant
  choices in any mode (**D-035**).
- *What if vetoes eliminate every option?* `outcome/1` returns `:no_consensus`, distinguishable
  from "nobody has voted yet", and deliberately does **not** crown the least-vetoed option
  (**D-034**).

**Still open — the floor.** Nothing caps total vetoes across the pool: one per participant,
unlimited in aggregate, so any group with as many participants as options can veto everything and
land in `:no_consensus`. Whether to block a veto at ≤2 surviving options, or to keep instant
removal and let `:no_consensus` be a real outcome the results screen renders honestly, is
undecided. Related and also undecided: with 5–8 voters each holding a veto, one person can
unilaterally kill anything — instant removal, or a heavy downweight?

**Q-9, Q-10 and Q-11 have been deleted from this file**, per the rule at the top. The
`participants` and `votes` tables are migrated and live in
`priv/repo/migrations/20260808210450_create_voting_tables.exs`, with the schemas in
`lib/consensus/voting/`. They answer all three: `votes.kind` is `"approve" | "veto"` read through
`Ecto.Enum` and there is deliberately **no** rank or weight column, since ranked-choice is
Post-MVP (Q-9); `participants` exists with group scoping, display name, `kind`, token and
`voted_at` (Q-10); and `users` exists and predates all of it (D-003, D-004), so the organizer is
an account, not a participant with a role flag (Q-11). Anonymity is not a per-group behaviour —
see D-035 — so there is no anonymity flag on `participants`, and there is no `veto_used` flag
because a ballot is submitted whole and once (D-036). The surviving numbers are unchanged, so this
section runs Q-8 then Q-12.

### Q-12. Ambiguous fields in the sessions/options schema

- `status` has `'voting' | 'locked' | 'completed'` — what's the difference between locked and
  completed, and what moves a session between them?
- `share_code` is `VARCHAR(8)` but the example URL is `XYZ-123` and the example code is `BFA82X`.
  Pick a length and alphabet (ambiguity-free: no O/0/I/1), and decide whether the code is the only
  credential needed to vote.
- `deadline` is `TIMESTAMP` (no zone) — must be `TIMESTAMPTZ`; a group-scheduling app with a hard
  lock time cannot be zone-naive.
- Who closes the session at the deadline? Cron, scheduled job, or lazy evaluation on read? Lazy is
  simplest and needs no scheduler, but then "voting closed" only becomes true when someone looks.

---

## Non-blocking — revisit later

### Q-13. Is PWA-as-installable actually part of the MVP?

The value proposition is "click a link, vote in a browser." Service worker, manifest, and install
prompts are orthogonal to that. Likewise the roadmap's "offline resilience" localStorage buffer:
for a 10-second voting interaction with a hard deadline, an offline write queue may be
over-engineering. Mobile-web-first is required; installability may not be.

### Q-14. Swipe UI vs. list voting for the MVP

The PRD offers both ("swiping or list voting"). Swipe physics is real frontend work; a compact
visual list with vote buttons is faster to build and easier to scan for the foodie persona who
wants to compare options side by side. Decide which ships first.

### Q-15. Phase schedule and staffing

The roadmap's 18-week, three-phase plan assumes an unstated team size and velocity. If this is a
solo build, the milestone boundaries are still useful but the week numbers aren't. Restate as
ordered milestones with explicit exit criteria rather than dates.

### Q-16. Where does the polymorphic seam actually go?

Phase 2 is a refactor *from* dining-specific columns *to* generic `option_id` + JSONB. Since
nothing is built yet, we can start activity-agnostic and skip the migration entirely — the PRD
already names it as core IP. Open question is only how far to go: JSONB blob, or per-activity
validation (Zod schema per `activity_type`) enforced at the API boundary from day one.
