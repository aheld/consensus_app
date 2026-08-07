# Open Questions

Everything that needs a decision before implementation starts. Resolved items move to
[decisions.md](decisions.md) and get deleted from here.

The draft roadmap answers several of these already; they're listed because the answers are
worth re-examining, not because the doc is silent.

---

## Blocking — decide before writing code

### Q-1. One deploy target or two?

The draft splits frontend (Vercel) from backend (NestJS on Render / ECS Fargate). That's two
deploys, two envs, a CORS surface, and two things to pay for — largely because persistent
WebSockets don't run on Vercel functions.

Alternative: keep everything in Next.js (route handlers + server actions) and get realtime from a
managed service, so nothing needs to hold an open socket in our own process.

**Bearing on this:** the PRD itself (§4) proposes "PostgreSQL with Supabase Realtime," which
contradicts the roadmap's NestJS + Socket.io + Redis pub/sub. The two source docs disagree and
one of them has to give.

### Q-2. Realtime transport: managed, self-hosted sockets, or polling?

Three real options for "votes update without a refresh":

| Option | Cost of complexity |
|---|---|
| Managed realtime (Supabase / Ably / Pusher) | Near zero infra; vendor dependency |
| Own WebSocket server + Redis pub/sub | Highest — stateful nodes, horizontal scaling, the roadmap's Risk #2 |
| Short polling (2–3s) on a session endpoint | Almost none; slightly less crisp |

Sessions are 5–8 people and live for hours, not days. Polling is likely indistinguishable from
sockets at this group size and deletes the entire "WebSocket flooding" risk. Worth deciding
deliberately rather than defaulting to sockets because they sound right.

### Q-3. Is Redis actually needed?

The draft uses Redis for two unrelated jobs: WebSocket room fan-out and caching third-party
search results. If Q-2 resolves to managed realtime or polling, job one disappears. Job two — a
24h cache of "tacos in Santa Monica" — can be a Postgres table with a TTL column and a unique
index on the normalized query. That would remove a whole piece of infrastructure from the MVP.

### Q-4. Guest identity — localStorage is not enough

Milestone 1.1 puts guest sessions in `localStorage`. Two problems:

1. **In-app webviews.** iMessage and WhatsApp open links in their own webview, whose storage is
   separate from (and less durable than) the user's real browser. A voter who reopens the link
   from the chat thread can land in a fresh storage context and appear as a new participant.
2. **Integrity.** "One vote per voter" and "one veto per voter" are unenforceable if identity
   lives entirely client-side. Anyone can clear storage and vote again.

Likely need a server-issued participant token in an httpOnly cookie, with `localStorage` as a
convenience mirror only. Decide the identity model before the schema is written — it touches
`participants`, `votes`, and every guarded mutation.

### Q-5. Do booking deep-links actually exist?

Phase 1 promises a "Book Now deep-link router pointing to OpenTable and Resy checkout endpoints."
Neither platform offers public deep-link/booking APIs at hobby tier. The redirect-gateway
mitigation (Risk #3) is the right *shape*, but the premise needs a spike first. Realistic
fallbacks: restaurant's own site, a Google Maps place link, or a platform search URL prefilled
with name + party size.

The PRD's own Phase 1 lists this as a technical spike — run it before committing "Instant Booking
Action" to the MVP as specified.

### Q-6. Places/Yelp: which provider, and does caching survive their terms?

- **Google Places** moved to per-SKU pricing; a naive search-as-you-type loop gets expensive fast.
- **Yelp Fusion** access terms have tightened; confirm current availability and whether our use
  qualifies.
- Google Maps Platform terms restrict how long non-ID place content may be cached. The roadmap's
  headline cost mitigation *is* a 24-hour cache — verify that's permitted before it becomes
  load-bearing. Place IDs and our own derived data are the safer things to persist.

Also unstated: **what's the monthly infra + API budget?** That number decides most of Q-1 → Q-3.

### Q-7. How does anyone learn the winner?

PRD persona relief for Rachel: "receives an automatic winner notification." With no accounts, no
email, and no push, we have no delivery channel. Web push on iOS requires an installed PWA — which
contradicts the zero-friction premise for guests.

Realistic MVP: the organizer gets a generated summary string to paste into the group chat (already
in the PRD), and the session link itself becomes the results page. Optional phone/email capture is
friction we said we wouldn't add. Needs an explicit call.

---

## Spec gaps — the two docs disagree or omit something

### Q-8. Veto semantics are underspecified

MVP includes: "Each voter can apply one Veto … instantly removing it from the eligible list."
Undefined:

- What happens to votes already cast for a now-vetoed option? Refund, or silently lost?
- Can a veto be withdrawn?
- If voting is anonymous, is the veto anonymous too? Options vanishing without attribution is
  confusing; attributed vetoes reintroduce exactly the social pressure the feature exists to remove.
- What if vetoes eliminate every option? Need a floor (e.g. veto blocked when ≤2 options remain).
- With 5–8 voters each holding a veto, one person can unilaterally kill anything. Is instant
  removal right, or should veto be a heavy downweight?

### Q-9. The vote schema doesn't match the PRD

PRD's Vote has `preference_type (yes/no/veto)`. The roadmap's `votes` table has `rank_weight` but
**no** veto representation — despite veto being an MVP must-have and RCV being Post-MVP. The
schema currently models the Post-MVP feature and drops the MVP one.

### Q-10. `participants` table is missing

`votes.participant_id` is declared as a foreign key to `participants.id`, but no `participants`
table is defined anywhere in the roadmap. Needs: session scoping, display name, anonymity flag,
identity token (see Q-4), veto-used flag, joined/last-seen timestamps.

### Q-11. No `users` table either

`sessions.organizer_id` references `users.id`. Organizer accounts are Post-MVP. For the MVP the
organizer is presumably just a participant with a role flag plus a secret organizer token — decide
whether `users` exists at all in v1.

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
