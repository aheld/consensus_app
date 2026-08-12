# Custom deadline picker, and the time zone seam under it

**Status:** **built, 2026-08-11 — see [D-055](../decisions.md).** Written the same day, and kept
as written: the plan below is the record of what was decided *before* the code, so where the build
diverged from it that is worth seeing rather than editing away. Three things it did not predict, all
recorded in D-055: `Deadlines.compact_reading_for/3` had to be added because `GroupLive.Share`'s
format is genuinely its own (§4 assumed one shared label function); `group_fixture/2` broke on the
new changeset rule and had to stop smuggling a past deadline through the organizer's write path
(§5 spotted the rule, not its fallout); and the picker is pre-filled on `:edit`, which needed a
closed-picker clause in the change detector to be safe at all.

Closes the last unbuilt control in the creation flow: the dashed, `disabled` `Custom…` chip on
design frame `01 setup` ([new.ex:338](../../lib/consensus_web/live/group_live/new.ex:338)),
deferred by **D-031**.

## 1. What is being built, and why it is two things

**The PRD requirement.** §5.1 A now records "organizer-defined deadline" as ⛔ — the deadline is one
of three presets (tonight 5pm / tomorrow 5pm / Thursday noon), so a Saturday-afternoon plan cannot be
given a Saturday-afternoon deadline. That binds Jessica the Planner hardest and it caps the product
at plans that happen to fall on one of three instants.

**Why it is not just a form field.** D-031 chose offset arithmetic over a time zone database and
recorded the cost honestly: *"an offset is a fixed number, not a rule, so a DST transition that falls
inside the window between `now` and the computed deadline shifts the result by an hour … Acceptable
for a same-day-to-one-week deadline picker; **not acceptable for anything computed further out**."*

A custom picker is exactly "further out". The window stops being ≤7 days and becomes whatever the
organizer types. So this feature has two halves and the second is the load-bearing one:

1. **The zone seam** — replace offset arithmetic with real zone rules. (§3, §4)
2. **The picker** — a native `datetime-local` input in the chip row. (§6)

Half 1 is worth doing on its own merits: it retires D-031's known limitation for the three existing
chips too, and it fixes the guest-side display on `/join` at the same time.

### The failure this exists to prevent

On 25 Oct in New York, an organizer picks **Nov 8, 7:00 PM**. Today's browser offset is −240 (EDT);
on Nov 8 it is −300 (EST).

- Offset arithmetic stores `2026-11-08T23:00Z`, which is **6:00 PM** on the day in question. Voting
  closes an hour early and nothing says so.
- Worse, it is immediately visible: the server renders the stored instant back through
  `Deadlines.label_for/3` using *today's* offset, so the organizer picks 7:00 PM and the confirmation
  chip reads **8:00 PM**. That does not read as a subtle DST bug; it reads as a broken form.

A picker also introduces two wall-clock times the chips can never produce: one that **does not
exist** (02:30 on spring-forward day) and one that **happens twice** (01:30 on fall-back day). Offset
arithmetic silently invents an answer for both.

## 2. What is explicitly not being built

- **No session time zone column.** The deadline stays a UTC instant, and every screen keeps rendering
  it in the *viewer's* own local time — which is already correct, because the deadline answers "by
  when must I vote", and a guest in California should see 4:00 PM for a 7:00 PM Eastern close.
- **No zone picker for the organizer.** A travelling organizer (setting up a Philadelphia dinner from
  a Denver airport) still picks in the browser's zone. Named here so it is not rediscovered as a bug;
  making the zone visible and editable is a later addition on top of this seam, not part of it.
- **No recurring sessions.** D-031 named these as the thing that would need real zone arithmetic. They
  now can have it, but nothing here builds them.

## 3. Decisions this plan takes

### D1. The dependency is `tz`, with its updater deliberately not started

`{:tz, "~> 0.28"}` (0.28.2, 2026-05-27). It compiles the IANA database into the application at build
time. **Its periodic-update process is not added to the supervision tree**, and that is the whole
point: D-031's objection was not to zone data, it was to *"a runtime data download, a periodic
updater, and a new failure mode at boot on a machine whose whole job is to serve one SQLite file."*
Compiled-in data with no updater has none of those three. The data refreshes on redeploy.

Rejected, with reasons, so nobody re-litigates:

- **`tzdata`** — the default choice, and the one D-031 was actually describing. It downloads the
  database at runtime and keeps it current over HTTP. Every objection in D-031 applies to it verbatim.
- **`zoneinfo`** — reads the OS's `/usr/share/zoneinfo`. Cheapest in Elixir terms and worst in
  operational terms here: the runner image installs `locales` but not `tzdata`
  ([Dockerfile:80](../../Dockerfile)), so it needs a Dockerfile change, and it converts a missing
  OS package into a runtime failure on a single machine with no second copy. That is a new boot
  failure mode of exactly the kind `Consensus.BootCheck` exists to catch — and having a mechanism to
  catch it is not a reason to create it.

**Staleness is the accepted cost.** IANA ships several releases a year; a compiled-in database goes
stale between deploys. For deadlines 1–2 days out (the PRD's stated market) that only matters for a
zone whose rules changed in the gap, which is rare and self-healing on the next deploy.

### D2. The browser's IANA zone name is authoritative; the offset is the fallback

[app.js:38](../../assets/js/app.js) **already sends** `tz: Intl.DateTimeFormat().resolvedOptions().timeZone`
and nothing in `lib/` reads it — verified by grep. Half of this is plumbed already.

The resolution order is `zone → offset → UTC`:

| what the client sent | what we use |
|---|---|
| a zone name the database knows | that zone — correct at any future date |
| a zone name it does not know (stale client, spoofed param) | the offset, exactly as today |
| no connect params at all (dead render, no JS) | **UTC** |

**The fallback is UTC, not a guessed regional zone.** "Assume EST" was considered and rejected twice
over: `EST` is the fixed −5 offset that the US East Coast is *not* on for eight months of the year
(it is on EDT, −4, right now), so it would be wrong more often than right even for its own region;
and the fallback is nearly unreachable anyway, since the connect params arrive on every LiveView
connect and **nobody can operate a date picker without a connected LiveView**. A default that only
applies to clients which cannot use the feature is not a safety net.

### D3. On an ambiguous or nonexistent wall-clock time, take the **later** instant

`DateTime.new/4` returns `{:ambiguous, first, second}` for the repeated hour and `{:gap, just_before,
just_after}` for the skipped one (contract verified against Elixir 1.20.3). One rule covers both:
**a deadline may never arrive earlier than the organizer's own words imply**, so take `second` and
`just_after` respectively. Both choices give voters at least as much time as they expect; the
alternatives cut voting off early on a date nobody was thinking about.

### D4. The picker is one native `<input type="datetime-local">`

Native pickers on iOS and Android, no date library, no new hook for the UI itself. There is **no
design frame for a custom picker** — `docs/design/screens/` has none — so this is a design call, not a
transcription, and it gets recorded in `DESIGN-SPEC.md` rather than reviewed against a drawing.

**Invariant 18 binds it:** the input must compute at **≥16px** or iOS Safari zooms the page on focus
and does not zoom back.

### D5. The wall-clock → instant conversion happens on the server

The browser could do it (`new Date(...)` has full zone rules), and that was considered. It fixes
storage and leaves display broken — the pick-7-see-8 confirmation above is a *rendering* bug, and it
recurs for every guest on `/join`. One conversion path on the server, fed by the zone name, fixes
both. It is also the only version that is testable in ExUnit, which is D-031's own stated objection
to computing any of this in JavaScript.

## 4. API surface

### `Consensus.Deadlines` — the signature change

Every public function takes `tz_offset_minutes` today. Threading a second `zone` argument through
all of them would produce five two-argument call sites that can disagree. Instead one value carries
both:

```elixir
defmodule Consensus.Deadlines.Clock do
  @moduledoc "How one viewer's browser told us to read a wall clock. See D-055."
  defstruct zone: nil, offset_minutes: 0
end
```

- `Deadlines.clock_from_params(connect_params)` → `%Clock{}` — **the one place** connect params are
  read, replacing the four near-identical private `read_tz_offset`/`assign_tz_offset` helpers now
  duplicated across `GroupLive.New`, `GroupLive.Review`, `GroupLive.Share` and `JoinLive.Results`.
  Adding a fifth copy for `tz` is how this seam would rot.
- `options(now_utc, %Clock{})`, `resolve(key, now_utc, %Clock{})`, `label_for(at, now_utc, %Clock{})`
  — same behaviour, correct across DST.
- **New:** `from_wall_clock(%NaiveDateTime{}, %Clock{})` → `{:ok, DateTime.t()} | {:error, atom()}`
  — the picker's conversion, applying D3.
- `countdown/2` is unchanged. It is a pure duration between two instants and has never involved a
  zone.

The `%Clock{}` with `zone: nil` reproduces today's arithmetic exactly, so the migration is
mechanical and each call site can move independently.

### Five call sites, and one of them is not obvious

1. `Consensus.Deadlines` itself.
2. `GroupLive.New` — the chips, `resolve/3`, `label_for/3`, and the new picker.
3. `GroupLive.Review` — `closes_label/3`.
4. **`GroupLive.Share` — has its own private `shift/2` and `closes_phrase/3`
   ([share.ex:97–103](../../lib/consensus_web/live/group_live/share.ex:97)), duplicating the wall-clock
   math outside `Consensus.Deadlines` entirely.** Migrating only the callers that reference
   `Deadlines` leaves the share sheet — the screen whose whole job is producing the artifact the group
   reads — silently on offset arithmetic. Fold it into `label_for/3` as part of this work.
5. `JoinLive.Results` — `label_for/3` at line 307, the guest-facing one.

### `Group.changeset/2` — `deadline_at` has no validation at all

Verified: it is `cast` and never `validate`d — not required, not bounded, not checked for being in
the future. **The three chips were the only thing guaranteeing a future deadline**, because they
compute one. A free-text picker removes that guarantee, so the rule has to move into the changeset
where it belongs:

- must be strictly in the future at insert/update time;
- an upper bound (proposed: **1 year**) — not a real product limit, a guard against a mistyped year
  producing a session that can never complete, since `maybe_complete_group/1` only fires on read.

Both are changeset validations, not UI constraints, for the same reason invariant 11 gives: the
changeset is the real limit and the input is a courtesy.

## 5. Failure modes

| condition | behaviour |
|---|---|
| no connect params (dead render) | `%Clock{zone: nil, offset_minutes: 0}` → UTC. The picker is not usable in this state anyway. |
| zone name the database does not know | fall back to the offset. Never crash — a stale or spoofed `tz` is untrusted client input. |
| picked time does not exist (spring gap) | `just_after` (D3) |
| picked time happens twice (fall ambiguity) | `second` (D3) |
| picked time is in the past | changeset error, rendered in the existing `deadline_error_message/1` slot |
| picked time is absurdly far out | changeset error, same slot |
| browser sends a malformed `datetime-local` value | `NaiveDateTime.from_iso8601/1` returns `{:error, _}` → changeset error, no crash |

### One premise this feature deletes

[new.ex:151–169](../../lib/consensus_web/live/group_live/new.ex:151)'s `keep_selected_deadline/2`
guards a real, reproduced race: a chip click and a keystroke in the same tick serialise a still-empty
hidden field, and the browser's blank overwrites the selection. Its correctness argument is quoted in
the code:

> A blank `deadline_at` can never mean "the organizer cleared it": the only controls that write it are
> the three chips, and `Custom…` is disabled. So a blank always means "the form went out before the
> patch came back", and the server's own selection wins.

**This feature is what makes that false.** A picker is a fourth writer, and it is one the organizer
can genuinely blank. The race still needs guarding, so the guard has to be re-derived — most likely by
distinguishing "the field was never populated" from "the field was cleared", rather than treating
every blank as a lost patch. Do not extend the existing helper without revisiting its comment; the
comment is the specification.

## 6. Verification

- **`Consensus.Deadlines` unit tests across real DST boundaries**, in both hemispheres and in a zone
  with neither (`America/New_York`, `Europe/London`, `Australia/Sydney`, `Asia/Kolkata` for the
  half-hour offset, `UTC`). The module is already pure and table-tested across seven weekdays and
  several offsets; this extends the same shape.
- **The pick-7-see-8 regression as its own named test** — set a deadline across a DST boundary and
  assert `label_for/3` renders back the hour that was picked. It is the failure a reader of this
  feature will actually hit, and it fails today.
- **Gap and ambiguity as explicit cases**, asserting D3's later-instant rule rather than asserting
  whatever the implementation happens to return.
- **`GroupLive.New`** — picker renders, converts, rejects a past date, survives the chip/keystroke
  race in both directions, and the fourth "stored" chip labels a custom pick correctly.
- **The `Share` duplicate** — a test that fails while `share.ex` keeps its private `shift/2`.
- **Invariant 18** — the computed font size of the new input, measured, ≥16px.
- **The fallback ladder** — three tests: known zone, unknown zone (falls to offset), no params (UTC).
- `mix precommit`, and CI's docker job as usual. Nothing here touches the boot path, so the release
  smoke tests are unaffected — but `tz` compiling into the release image is worth confirming in the
  image rather than only in `mix test`.

## 7. Docs this must update when it lands

Per the working agreement that a new decision must edit every earlier entry it invalidates:

- **`decisions.md`** — a new **D-055**, and **D-031 amended in place**: its decision stands for how
  the chips are *labelled* but its "we carry no time zone database" premise and its **Known
  limitation** paragraph are superseded. Its rejected alternative *"Add `tzdata` and resolve a named
  zone — correct, and disproportionate. Revisit when a feature needs real zone arithmetic"* is
  precisely the trigger firing; say so there rather than leaving it reading as a live refusal.
- **`PRD.md` §5.1 A** — flip the ⛔ custom-picker bullet and its status-table row, and drop the
  "Building it means deciding the timezone question D-031 parked" clause, which this closes.
- **`CLAUDE.md`** — the dependency, and `Consensus.Deadlines`' line in the repo-layout tree, which
  currently reads *"pure; the 01-setup chips + countdown, offset arithmetic only"*.
- **`docs/design/DESIGN-SPEC.md`** — the picker's treatment, as a design call with no frame behind it.
- **`open-questions.md`** — nothing to strike; no `Q-` covers this. D-031 parked it in the decision
  log rather than the question list, which is why it stayed invisible.
