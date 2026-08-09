# SQLite capacity and implementation review

- **Date:** 2026-08-08
- **Reviewer:** adversarial review round, data layer only
- **Status:** review, not a decision. A proposed `D-038` is drafted at the bottom; `decisions.md` was not edited.
- **Scope:** the choice of SQLite, and the correctness of this repo's SQLite implementation, at the owner's stated scale (dozens of users, one `shared-cpu-1x` Fly machine, no high concurrency expected).

---

## Bottom line up front

1. **SQLite is the right call and should stay.** Dozens of users on one small machine is exactly its envelope, and this app's data is relational with foreign keys and cascades — nothing about the workload argues for a network database.
2. **But the app ships with `pool_size: 5`, and on SQLite that is the bug, not the safety margin.** Measured: 15 voters submitting inside 2 seconds gives **p95 25.8 s and max 38.9 s** per ballot. The same burst at **`pool_size: 1` is p95 10.6 ms / max 127 ms** — roughly 2,400x better. Five connections racing one write lock build a convoy; one connection makes DBConnection's fair queue do the serialising instead.
3. **The trigger to leave SQLite is not concurrency, it is ~50+ voters routinely submitting inside the same few seconds, or the day you need two machines.** After the pool fix this design absorbs a 64-voter simultaneous burst at p50 74 ms; you will run out of *operational* headroom (one machine, one volume, deploy = outage) long before you run out of write throughput.
4. **The real risk here is backups, not throughput.** RPO is 24 hours, the restore runbook has never been executed, and `fly.toml` has silently lost `snapshot_retention = 30` so retention is now Fly's 5-day default.
5. **`fly.toml` has been overwritten by `fly launch` with placeholder values and will fail its first deploy** — the volume now mounts at `/mnt/name`, which the Dockerfile does not prepare. `deploy_config_test.exs` passes green on it.

---

## How this was measured, and what does not transfer

Everything numeric below was produced on **this Mac** (Apple silicon, APFS, 10 dirty-IO schedulers), against throwaway SQLite files under a `tmp_dir`, using a second dynamic `Consensus.Repo` instance with a real `DBConnection.ConnectionPool` — the technique [test/consensus/voting_concurrency_test.exs](../test/consensus/voting_concurrency_test.exs) established, because `max_cases: 1` (D-033) makes the suite itself incapable of genuine concurrency. Benchmarks ran at **production's settings** (`journal_mode: :wal`, `busy_timeout: 5_000`, `default_transaction_mode: :immediate`, `pool_size` varied), on `MIX_TEST_PARTITION=41`. The benchmark files were throwaway and are not in `test/`.

**What transfers and what does not.** The pathology below is a **lock convoy in SQLite's busy handler**, not a disk-speed effect. That is established, not assumed: re-running with `synchronous: :off` changed nothing (p50 1461 ms vs 1543 ms), so fsync is not implicated. A convoy is a contention and scheduling artifact, so it will reproduce on Fly, and a slower shared vCPU should make it somewhat worse, not better. What does **not** transfer is the absolute best-case latency: the sub-10 ms figures in the `pool_size: 1` rows are Mac NVMe numbers, and Fly's network-attached volume on a shared CPU will be slower — I would expect single-digit to low-tens of milliseconds rather than 3 ms, but I have not measured it and **nothing in this repo has ever run on Fly at all** (open-questions F-2).

Distinguish throughout: **MEASURED** means I ran it; **REASONED** means I did not.

---

## 1. The measurement

### 1.1 The realistic case — a deadline burst (MEASURED)

The product's stated worst case is not steady traffic, it is one group's voters all tapping "send my votes" near the deadline. 15 voters, arrival times spread uniformly across a window, 5 repetitions pooled, 8-option pool, 2 approvals each:

| pool_size | arrival window | ok | refused | p50 | p95 | max |
|---|---|---|---|---|---|---|
| **5** (shipping) | 10 s | 75/75 | 0 | 3.2 ms | 35.4 ms | 206.8 ms |
| **5** | 2 s | 75/75 | 0 | 32.3 ms | **25,762 ms** | **38,888 ms** |
| **5** | 500 ms | 75/75 | 0 | 886.6 ms | **24,828 ms** | **37,142 ms** |
| **5** | 0 (simultaneous) | 75/75 | 0 | 942.3 ms | **13,667 ms** | 13,765 ms |
| **1** | 10 s | 75/75 | 0 | 3.0 ms | 11.1 ms | 111.5 ms |
| **1** | 2 s | 75/75 | 0 | 3.6 ms | 10.6 ms | 127.0 ms |
| **1** | 500 ms | 75/75 | 0 | 5.1 ms | 10.5 ms | 12.5 ms |
| **1** | 0 (simultaneous) | 75/75 | 0 | 19.1 ms | 25.5 ms | 29.2 ms |

**The knee for the shipping configuration sits between "15 ballots over 10 seconds" and "15 ballots over 2 seconds."** Spread the same 15 voters over ten seconds and everything is fine; compress them into two and the tail goes to 38 seconds.

Read the success column carefully before relaxing: **no ballots were refused**, because D-034's bounded jittered retry is doing its job. The failure mode at `pool_size: 5` is not lost ballots, it is a guest staring at a spinner for half a minute — and see §1.4, where that turns into a lost ballot after all.

### 1.2 The synthetic sweep — N simultaneous ballots (MEASURED)

All N ballots parked on a message and released together. 4 repetitions per cell.

| pool | N | ok | refused | p50 | p95 | max |
|---|---|---|---|---|---|---|
| 1 | 4 | 16/16 | 0 | 6.4 ms | 11.7 ms | 12.5 ms |
| 1 | 8 | 32/32 | 0 | 9.9 ms | 12.8 ms | 13.7 ms |
| 1 | 16 | 64/64 | 0 | 17.9 ms | 36.1 ms | 38.9 ms |
| 1 | 32 | 128/128 | 0 | 39.4 ms | 78.2 ms | 82.8 ms |
| 1 | 64 | 256/256 | 0 | 74.3 ms | 102.6 ms | 128.9 ms |
| 5 | 4 | 16/16 | 0 | 9,061.8 ms | 13,607.0 ms | 13,647.2 ms |
| 5 | 8 | 32/32 | 0 | 5,385.2 ms | 21,105.6 ms | 21,171.8 ms |
| 5 | 16 | 64/64 | 0 | 5,441.8 ms | 31,345.4 ms | 31,450.5 ms |
| 5 | 32 | 127/128 | 1 | 6,343.9 ms | 34,526.6 ms | 41,883.9 ms |
| 5 | 64 | 200/256 | **56** | 12,079.0 ms | 45,115.0 ms | 50,777.8 ms |

At `pool_size: 1` the relationship is linear and boring — which is what you want. At `pool_size: 5` it is chaotic (N=4 measured *worse* than N=8 in this run; convoys are like that) and at N=64 the retry budget is finally exhausted and **56 of 256 ballots are refused outright**.

### 1.3 Why — the phase breakdown (MEASURED)

Timing each phase of a ballot separately, N=8 simultaneous, `pool_size: 5`, retry wrapper removed so failures are visible:

```
total 5427.5  r1 0.2  r2 0.3  r3 0.4  r4 0.2  TXN 5426.4  {:raised, Exqlite.Error}
total 5429.0  r1 0.1  r2 0.3  r3 0.4  r4 0.2  TXN 5428.0  {:ok, :voted}
total 5430.2  r1 0.2  r2 0.4  r3 0.3  r4 0.2  TXN 5429.1  {:ok, :voted}
   (r1 = participant re-read, r2 = group re-read, r3/r4 = ensure_all_in_group, TXN = Repo.transact)
```

with the raised error being, verbatim:

```
** (Exqlite.Error) database is locked
BEGIN IMMEDIATE TRANSACTION
```

**Every pre-transaction read is sub-millisecond. 100% of the delay is inside `BEGIN IMMEDIATE`,** where connections sit in the busy handler for the full 5,000 ms `busy_timeout` and then several fail together.

This vindicates D-034 completely and reframes it. Validating outside the transaction was the right call and the transaction really is as short as the moduledoc claims — it is not the problem. The problem is one layer down: **five pooled connections all attempting `BEGIN IMMEDIATE` against a single write lock**. SQLite's busy handler is a sleep-and-retry loop, not a queue, and it is documented as unfair; once several connections are in it they collide, back off, and collide again, so a loser can burn its entire timeout while the actual work being contended for takes 0.3 ms. Corroborating evidence that it is contention and not I/O:

- A **raw** `BEGIN IMMEDIATE` / `UPDATE` / `COMMIT` with no preceding reads, 8 concurrent at `pool_size: 5`: p50 21.8 ms, max 855.9 ms, none over 1 s. SQLite serialises writes perfectly well when the connections arrive cleanly.
- `synchronous: :off`: no meaningful change. Not fsync.
- A pool-size sweep at N=8 shows no monotonic relationship at all (pool 3 measured worse than pool 5; pool 10 worse than pool 20) — the signature of a chaotic convoy rather than a queueing curve. Only `pool_size: 1` is stable, because at 1 there is no SQLite-level contention left to be unfair about: DBConnection's own FIFO queue does the serialising.

`PRAGMA busy_timeout` reporting `0` on these connections is expected and is not evidence the timeout is unset — exqlite installs its handler through a NIF (see the `sqlite` skill).

### 1.4 The product consequence, and a real bug hiding inside it

At `pool_size: 5` a ballot cast a few seconds before the deadline can sit in the convoy for 25–39 seconds. `Consensus.Voting.commit_ballot/3` re-checks `ensure_before_deadline/1` **inside** the transaction, and `with_busy_retry/2` re-runs the whole chain on each attempt — both correct in isolation. Together they mean:

> **A ballot submitted before the deadline, delayed past it by the convoy, is refused with `{:error, :deadline_passed}` and lost.**

So the "no ballots refused" column in §1.1 is only true away from a deadline. Near one — the exact moment the burst happens — the convoy converts latency into destroyed votes. This is REASONED from the code paths plus the measured 38.9 s tail, not directly reproduced with a deadline in the window; it would be worth a test.

**How many simultaneous voters does this design comfortably absorb?**

- **As shipped (`pool_size: 5`): about 2.** Beyond two genuinely-overlapping writers the tail latency becomes user-visible; by 15-inside-2-seconds it is a broken screen.
- **With `pool_size: 1`: at least 64, measured, at p50 74 ms / max 129 ms.** For a "dozens of users" product this is not a ceiling you will find. REASONED estimate for Fly's slower disk and shared vCPU: multiply by something like 3–10x and it is still comfortable at 64.

### 1.5 The read side (MEASURED)

Every `{:ballot_cast, group_id}` broadcast makes every mounted results LiveView — both [lib/consensus_web/live/group_live/results.ex](../lib/consensus_web/live/group_live/results.ex) and [lib/consensus_web/live/join_live/results.ex](../lib/consensus_web/live/join_live/results.ex) — call `reload/1`, which re-runs the group lookup, `Voting.tally/1` and `Voting.participants/1`. That is **5 queries per viewer per ballot** (group by slug/id; activities; two `count_votes` group-bys; participants), plus a 30 s `:tick` doing the same.

One full reload, measured:

| shape | p50 | p95 |
|---|---|---|
| 8 options / 5 voters | 0.4 ms | 1.9 ms |
| 8 options / 20 voters | 0.3 ms | 0.7 ms |
| 20 options / 50 voters | 0.5 ms | 0.7 ms |

Under load — 16 viewers reloading continuously while 8 ballots land:

| pool | read p50 | read p95 | read max | write p50 | write max |
|---|---|---|---|---|---|
| 1 | 7.2 ms | 9.4 ms | 15.6 ms | 10.7 ms | 12.7 ms |
| 5 | 7.0 ms | 13.6 ms | **5,431.9 ms** | 5,427.1 ms | 5,576.8 ms |

**The read side is a non-issue at this scale, and `pool_size: 1` does not starve it** — WAL readers are cheap and the queries are indexed. Note the last row: at `pool_size: 5` the convoy stalls *readers* too, up to 5.4 s. Reducing the pool to 1 improves the read tail by ~350x here.

The cost is `O(viewers x ballots)` queries: 20 viewers and 15 ballots is 1,500 queries at ~0.4 ms, about 0.6 s of database work spread over the burst. Fine now. It is the first thing that would need attention at 10x — the fix is debouncing the reload, not a different database.

---

## 2. Implementation findings, by severity

### S1 — CRITICAL: `pool_size: 5` is the wrong pool size for SQLite

[config/runtime.exs](../config/runtime.exs) `:prod` block sets `pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")`; [config/dev.exs](../config/dev.exs) sets `pool_size: 5`.

The comment above it says extra slots "only ever help concurrent readers," and D-013's consequences repeat it. **The measurements say that is not neutral — it is actively harmful.** Extra connections do not merely fail to help writes; they manufacture write contention that would not otherwise exist, because each one independently races `BEGIN IMMEDIATE`. This is the single highest-value change available in this review, it is one line, and it makes the burst ~2,400x faster at p95.

Recommended (a reviewer's recommendation, not a change I made): `pool_size: 1` in the `:prod` block and in `config/dev.exs`. `config/test.exs` should be left alone — it runs the sandbox pool and `max_cases: 1` already serialises it.

**Before changing it, verify one thing** (I did not, and it is the only real risk): with a pool of one, any code path that holds the connection and then *waits on another process that also needs the connection* deadlocks. Ecto reuses the same connection for nested calls inside `Repo.transact/1`, so the transactions in `Consensus.Voting` and `Consensus.Activities` are safe. The path to check is `start_async` — a LiveView that holds a transaction while awaiting a task that queries. `Consensus.LinkPreview.fetch/1` is the only `start_async` caller and does no database work inside a transaction, so this looks clear, but confirm it deliberately.

An honest alternative, if a single connection feels too tight: separate read and write pools (a second repo, writes on a pool of 1). That is a real design change and would need its own decision entry. It is not needed at this scale.

### S2 — CRITICAL: `fly.toml` has been overwritten with `fly launch` placeholders and will fail its first deploy

`git diff fly.toml` shows the committed file replaced by generated output dated `2026-08-08T19:48:35-04:00`. Concretely:

| was | is now |
|---|---|
| `source = 'consensus_data'`, `destination = '/data'` | `source = 'name'`, `destination = '/mnt/name'` |
| `DATABASE_PATH = '/data/consensus.db'` | `DATABASE_PATH = '/mnt/name/name.db'` |
| `snapshot_retention = 30` | *(absent — reverts to Fly's 5-day default)* |
| `initial_size = '1gb'` | *(absent)* |
| `soft_limit = 200` / `hard_limit = 250` | `1000` / `1000` |
| every explanatory comment, including the "no `[deploy] release_command`" warning | *(deleted)* |

The load-bearing failure: [Dockerfile](../Dockerfile) line 100 does `RUN mkdir -p /data && chown nobody:root /data && chmod 750 /data`. It prepares **`/data`**. The volume now mounts at **`/mnt/name`**, which the image does not create or chown, so the release running as `nobody` meets a root-owned mount point. `Consensus.BootCheck` should catch it and raise `Cannot write the SQLite database` — which is the preflight working as designed (invariant 3), but it means a failed first deploy, and per D-012 that `RUN` line is the *only* intended departure from generator output.

Losing `snapshot_retention = 30` is the quieter half and it is a **backup regression**: per TODO.md §7 a volume's retention is fixed when the volume is created, so a volume created from this file gets 5 days, and editing `fly.toml` later will not change it.

**[test/consensus/deploy_config_test.exs](../test/consensus/deploy_config_test.exs) passes green on this file — verified, 7 tests, 0 failures.** It checks the stanzas agree *with each other* (`/mnt/name/name.db` does start with `/mnt/name/`; `PHX_HOST` does match `app`), which is D-023's brief. Nothing checks that `[[mounts]] destination` is the path the Dockerfile prepares. That is a genuine gap in an otherwise well-conceived guard, and it is cheap to close: assert the destination appears in the Dockerfile's `mkdir`/`chown` line.

Also worth noting: the `[env]`/`[[mounts]]` values are placeholders (`name`), not a deliberate relocation — nothing else in the repo refers to `/mnt/name`, while README, TODO, `boot_check.ex`'s remediation message (`chown -R 65534:0 /data`), D-012 and CLAUDE.md all still say `/data`.

### S3 — HIGH: backups are the largest real risk, and are weaker than the docs imply

This deserves to outrank concurrency, because concurrency degrades visibly and recoverably while a lost volume is final.

What exists today:

- **Fly daily volume snapshots.** RPO is **up to 24 hours**. Retention is now 5 days, not 30 (see S2).
- **No `VACUUM INTO`, no Litestream, no scheduled export.** `grep` finds neither anywhere in `lib/`, `config/`, `.github/` or `rel/`; the `sqlite` skill documents both as options and explicitly says Litestream "is not currently set up."
- **A restore runbook in TODO.md §7 (R1–R8) that has never been executed** and which necessarily destroys and recreates the Machine (D-019). Its own header says so.

Three specific problems:

1. **Is a snapshot of a live WAL database even consistent?** Not reliably. A Fly snapshot is a block-level copy of the volume taken while SQLite may be mid-transaction, and it captures `consensus.db`, `-wal` and `-shm` at possibly different instants. SQLite's recovery will usually cope — that is what the WAL is for — but "usually" is the operative word, and this is not a transactionally consistent backup. TODO.md §7 says exactly this already, which is to its credit.
2. **The workaround TODO.md offers has its own bug.** It recommends `fly sftp get /data/consensus.db ./prod.db` as "the more trustworthy backup." That copies **only the main database file and leaves the `-wal` sidecar behind** — precisely the mistake the `sqlite` skill warns about ("never copy only the `.db` file when a `-wal` sibling exists"). Every transaction committed since the last checkpoint is silently missing from that copy. The correct one-liner is `VACUUM INTO`, run against the live database over `bin/consensus rpc`, then sftp the *result*:
   ```
   Ecto.Adapters.SQL.query!(Consensus.Repo, "VACUUM INTO '/data/backup.db'", [])
   ```
   which folds the WAL in and produces a clean, consistent file while the app keeps running.
3. **RPO of 24 hours is a product decision nobody has made.** For an app whose unit of value is a group's session, losing a day means losing every group created that day. That may well be acceptable pre-launch — but D-012 accepts "however old the daily snapshot is" without anyone having priced it against the product.

None of this is a reason to leave SQLite; a `VACUUM INTO` on a timer plus off-box copy is a far smaller change than a database migration, and `VACUUM INTO` is a strictly better backup primitive than anything the Postgres free tiers give you at this size.

### S4 — MEDIUM: `synchronous` is never set and never decided

Measured on a live connection at production settings: `PRAGMA synchronous` → `[[1]]` (NORMAL), inherited from ecto_sqlite3. Nothing in `config/` mentions it.

NORMAL + WAL is the *correct default* and I am not arguing to change it — but the durability trade it encodes is real and undocumented: **a commit is acknowledged before the WAL is fsynced**, so a host failure or hard kill can lose the last transactions (it will not corrupt the database — that is FULL vs NORMAL's actual distinction in WAL mode). On a single Fly machine with no replica, that is the difference between losing zero ballots and losing the last few on a host failure.

D-013 writes out `journal_mode` and `busy_timeout` with the explicit reasoning that "a default that is load-bearing should be visible in the config file, not inherited silently from a dependency." `synchronous` meets that test exactly and was missed. Either state it explicitly with a comment, or record in `decisions.md` that NORMAL is a deliberate choice.

Related, same reasoning: [mix.exs](../mix.exs) declares `{:ecto_sqlite3, ">= 0.0.0"}`. D-013's stated fear is "a dependency bump could change it without a diff in this repo," and an unbounded requirement is the version constraint most likely to let that happen. `mix.lock` pins 0.24.1 in practice, so this is low-urgency, but a `~> 0.24` would match the stated intent.

### S5 — MEDIUM: two `Activities` writes crash instead of returning a tuple

[lib/consensus/activities.ex](../lib/consensus/activities.ex) has two `Repo.transact/1` calls (`delete_activity/2` at line 347 and `reorder_activities/3` at 396) and **no `rescue`** anywhere in the file. `Consensus.Accounts` rescues `Exqlite.Error` on both admin writes; `Consensus.Voting` rescues both `Exqlite.Error` and `DBConnection.ConnectionError` on both voter entry points (D-034).

So an organizer reordering their pool while the database is contended gets a crashed LiveView rather than a flash. D-034's consequences note this gap for `Accounts` and call widening "a reasonable follow-up"; the `Activities` pair is not mentioned anywhere and is the more reachable of the two, because reordering happens during the same wizard session in which a link-preview fetch and other writes are in flight. The `sqlite` skill already documents the gap — worth closing now that §1 shows how easily contention arises.

Severity is genuinely lower once S1 lands, because the convoy is what makes `Database busy` likely in the first place.

### S6 — MEDIUM: every deploy is an outage, and it lands on in-flight ballots

REASONED, not measured — nothing has been deployed (F-2).

One machine means `fly deploy` stops the old machine and starts the new one. The gap is image pull plus BEAM boot plus `Consensus.BootCheck` plus boot-time migrations plus seeding, and `kill_timeout = '30s'` allows the old one up to 30 s to drain. A reasonable expectation is **10–30 seconds of full unavailability per deploy**, plus every LiveView reconnecting afterwards.

For this product that is sharper than for most apps, because of the hard deadline. A deploy that lands in the 60 seconds before a group's deadline will drop the websockets of everyone on the ballot screen; LiveView reconnects, but any ballot not yet committed has to be re-submitted by the voter, and if the deadline passes during the restart it is refused permanently (D-036 — no recasting). The mitigation is procedural and free: **do not deploy while a group has an imminent deadline.** Nothing currently says so in TODO.md §5 or §7.

### S7 — LOW: portability is genuinely excellent

Worth recording as a positive finding because it is what makes the escape route cheap. `grep` across `lib/` finds:

- **Zero raw SQL.** No `Ecto.Adapters.SQL.query`, no `execute(`, no `fragment(`. Every query is portable Ecto.
- **No upserts, no `on_conflict`.** The one `insert_all` ([lib/consensus/voting.ex](../lib/consensus/voting.ex):624) uses no adapter-specific options.
- **`Ecto.Enum` over plain `:string` columns** in three places (`participants.kind`, `votes.kind`, `activity_groups.status`) — stored as text, portable verbatim.
- The only SQLite-specific artifacts are in `priv/repo/migrations/` (the literal `CREATE TABLE "home_page"` for a named CHECK) and `Consensus.BootCheck` / `Consensus.Release`, which are deployment glue, not queries.

The genuinely non-portable items are narrow and listed in §3.

---

## 3. The trigger, and the escape route

### 3.1 The trigger — what to watch, and where

Three signals, in the order they will actually fire. All are watchable from `fly logs` today, no new instrumentation.

**Trigger 1 — the pool convoy (fires now, at `pool_size: 5`).**
`Consensus.Voting.with_busy_retry/2` logs, at `:warning`:

```
[voting] ballot refused after 2 retries: database busy
```

and `{:error, {:database_busy, _}}` is a documented return of both `cast_ballot/3` and `create_participant/2`. Watch for:

```
fly logs --app consensus-app | grep -E "ballot refused after|database_busy|database is locked"
```

**Any occurrence of `[voting] ballot refused after` is a lost ballot and should be treated as a page, not a metric.** It means the retry budget was exhausted. Note that this line only fires at the *end* of the retry chain — the 25-second waits in §1.1 produce no log line at all, which is itself worth fixing (a `Logger.info` on each retry would make the convoy visible before it starts losing votes).

**Trigger 2 — the honest capacity signal, after S1 is fixed.** The number to watch is **simultaneous submitters per group**, not users, requests, or database size. Concretely:

> Leave SQLite when a single group routinely has **more than ~50 participants submitting inside the same 5-second window**, or when measured ballot p95 exceeds **1 second** on the Fly machine.

Measured headroom at `pool_size: 1` is 64 simultaneous at p50 74 ms / max 129 ms on this Mac; the 50-voter threshold deliberately sits below that with room for Fly's slower disk. At the owner's stated scale — 4–7 person sessions, dozens of users — this is roughly an order of magnitude away and may never fire.

**Trigger 3 — the one that will actually fire first, and it is not about performance.** Leave SQLite the moment any of these becomes true:

- you need **two machines** — for availability, for zero-downtime deploys, or for a second region (invariant 4 forbids it *because* of SQLite, and no amount of tuning changes that);
- an outage of 10–30 seconds per deploy stops being acceptable;
- a 24-hour RPO stops being acceptable and `VACUUM INTO` + off-box copy is not enough;
- real groups depend on the app, which D-012 already names as the point at which its accepted risk stops being acceptable.

This is the honest ordering. **The operational constraints of one machine will run out before SQLite's write throughput does.**

### 3.2 The escape route, priced in work

**How much of the codebase moves?** Almost all of it. Based on the §S7 grep, the migration is roughly:

| item | work |
|---|---|
| `lib/consensus/*.ex` context and query code | **none** — zero raw SQL, zero fragments, zero adapter-specific query options |
| `lib/consensus/repo.ex` | one line (`adapter: Ecto.Adapters.Postgres`) |
| `mix.exs` / `mix.lock` | swap `ecto_sqlite3` for `postgrex` |
| `config/{dev,test,runtime}.exs` | rewrite the repo blocks: hostname/username/password/database in place of `database:` path; drop `journal_mode`, `busy_timeout`, `default_transaction_mode` |
| `priv/repo/migrations/` | the `home_page` pair uses literal SQLite DDL (`20260808040000` up, `20260808183755` down). Both concern a dropped table. Simplest path: collapse to a fresh initial migration, which F-1 already establishes is this project's stance (down migrations are not maintained, the answer to a bad migration is a fresh database) |
| `Consensus.BootCheck`, `Consensus.Release` preflight | delete or heavily rewrite — volume/WAL-set probing is meaningless against a network database |
| `fly.toml`, `Dockerfile` | drop `[[mounts]]`, drop the `/data` `RUN`, add `DATABASE_URL` |
| `test/test_helper.exs` `max_cases: 1` | can revert to the default; D-033's whole cause disappears |
| `test/consensus/voting_concurrency_test.exs` | keep it, retune it — it stops being about a single write lock |
| rescues for `Exqlite.Error` in `Accounts` and `Voting` | become `Postgrex.Error`; the `{:database_busy, _}` contract can stay |
| CI's `docker` job, D-009's no-`release_command` rule | reopens — with a network database, a Fly `release_command` becomes the *correct* place for migrations again |
| docs | D-003, D-009, D-012, D-013, D-019, D-033, D-034 all need supersession entries; CLAUDE.md invariants 3, 4, 10, 15 all change |

**Realistic estimate (REASONED): 1–3 days of focused work for the code and config, plus a day for docs and CI, plus the data migration itself.** The code is the easy part precisely because nobody reached for raw SQL. The docs and the invariants are the long pole — this repo's documentation is unusually tightly coupled to the storage decision, which is a strength until you change it.

**Cost.** All figures below were verified against vendor pricing pages on **2026-08-08**; each is cited. Prices go stale — re-check before committing.

- **Neon** ([pricing](https://neon.com/pricing)) — Free tier: 0.5 GB storage per project, 100 CU-hours/month, 5 GB egress, scale-to-zero after 5 minutes and **not disableable on Free**; exceeding a monthly limit **suspends compute until the next billing month**. Paid "Launch" is metered with no monthly minimum: $0.106/CU-hour, $0.35/GB-month storage beyond 0.5 GB. Cold start after scale-to-zero is documented as "a few hundred milliseconds" ([docs](https://neon.com/docs/introduction/scale-to-zero)). For this app the free tier is genuinely sufficient on size, and the compute-suspension behaviour is the thing to watch, not the storage.
- **Fly Managed Postgres** ([docs](https://fly.io/docs/mpg/)) — cheapest plan is **Basic at $38/month** (shared-2x, 1 GB), plus $0.28/provisioned GB. There is nothing cheaper. Note **`ewr` is not among MPG's 12 regions** — nearest is `iad`.
- **Legacy unmanaged `fly pg create`** ([pricing](https://fly.io/docs/about/pricing/)) — just Machines and volumes you operate yourself: shared-cpu-1x 256 MB in `ewr` is $0.0027/hr ≈ **$1.94/month**, volumes $0.15/GB-month, so **~$2.09/month** for a single node with a 1 GB volume. But Fly's own docs now carry a banner: "We are not able to provide support or guidance for unmanaged Postgres." You would be operating a Postgres single point of failure yourself — strictly worse than the SQLite you already have, since it adds a network hop and a second thing to back up without adding redundancy.
- **Supabase** ([pricing](https://supabase.com/pricing)) — Free: 500 MB database, but **projects pause after 1 week of inactivity**, which is disqualifying for a low-traffic app that must answer a shared link at any hour. Pro from **$25/month**.

**The straight answer on latency:** today every query is an in-process function call against a file — the §1.5 measurements show 0.3–0.5 ms for a *whole results-screen reload* of five queries. Against Neon, each of those five becomes a network round trip. Fly `ewr` (Secaucus NJ) to Neon AWS `us-east-1` (N. Virginia) is roughly 4–10 ms — **my estimate, not a documented figure**; neither vendor publishes it. That makes a results reload ~25–50 ms instead of ~0.4 ms. Still fine, but it is a 50–100x increase on the read path, and it is the cost nobody mentions when comparing databases on price. Worth knowing: Fly's community tracked a real `ewr` → Neon `us-east-1` incident in November 2025 where an IPv6 upstream path produced 698 ms average latency until Fly hotfixed it ([thread](https://community.fly.io/t/very-slow-network-connections-between-ewr-and-us-east-1/26425)).

### 3.3 On Upstash Redis

Asked directly, so answered directly: **Redis is not a relational database and would not work here without rewriting the data model by hand.** Verified on [Upstash's pricing page](https://upstash.com/pricing) (2026-08-08), Upstash sells Redis, Vector, QStash, Workflow, Search and Box — **no relational or Postgres product at all**.

This app's schema is relational in the parts that matter most: `activity_groups.organizer_id → users` and `activities.group_id → activity_groups` are both `ON DELETE CASCADE`, `activities.added_by_id` is `ON DELETE SET NULL`, `votes.activity_id → activities` is `ON DELETE CASCADE` (and D-037 exists *because* of that cascade), and `Consensus.Accounts.delete_user/2` is built on referential actions doing the work — a plain `Repo.delete/1` that relies on two levels of cascade. There is also a partial unique index on `(group_id, user_id)` and a unique index on `(participant_id, activity_id)` enforcing "one ballot per person per option." Redis has none of these primitives; every cascade and every uniqueness rule would become application code, and every one of those is a place to introduce the orphaned-row bugs the database currently makes impossible.

What Redis *would* be good for, if a need appears: caching `Consensus.LinkPreview` results across restarts (today an ETS table that dies with the machine), or PubSub across multiple machines. Both are supporting roles beside a relational database, not replacements for one. Neither is needed at this scale.

### 3.4 The part worth stating plainly

Invariant 4 says never scale past one machine, and it says so **because of SQLite**. So the Postgres conversation is not really about write throughput — §1 shows there is ample throughput once the pool is fixed. It is about buying the *option* of a second machine: zero-downtime deploys, surviving a host failure, and a backup story that is somebody else's job. Those are the things this deployment cannot have today at any traffic level.

That is a real and eventually-compelling value. It is just not today's problem, and paying $38/month plus a 50x read-latency increase to solve a problem you do not have yet would be the wrong trade at dozens of users.

---

## 4. Recommended order of work

1. **`pool_size: 1`** in `config/runtime.exs` `:prod` and `config/dev.exs`, after checking the `start_async` deadlock question (S1). Highest value, one line, ~2,400x on the p95 that matters.
2. **Restore `fly.toml`** from `git show HEAD:fly.toml` and reapply only the intended changes (S2). This blocks the first deploy.
3. **Extend `deploy_config_test.exs`** to assert `[[mounts]] destination` matches the Dockerfile's `mkdir`/`chown` path, and that `snapshot_retention` is present and ≥ 30 (S2).
4. **Fix the backup one-liner in TODO.md §7** to `VACUUM INTO` then sftp, rather than sftp of a live `.db` (S3).
5. **State `synchronous` explicitly** in config with a comment, or record the default as deliberate (S4).
6. Widen the rescues in `Consensus.Activities` (S5); add a note to TODO.md not to deploy near a live deadline (S6).
7. Add a `Logger.info` per retry in `with_busy_retry/2` so convoy latency is visible before it becomes a lost ballot (§3.1).

---

## Appendix — proposed decision entry

Drafted here rather than appended to [decisions.md](decisions.md), which another agent is editing. Number is a placeholder; renumber on merge. Written in that file's template.

---

## D-0NN — The SQLite connection pool holds exactly one connection

- **Date:** 2026-08-08
- **Status:** proposed
- **Decision:** `pool_size` is **1** on `Consensus.Repo` in [config/dev.exs](../config/dev.exs) and the `:prod` block of [config/runtime.exs](../config/runtime.exs) (the `POOL_SIZE` environment override defaults to `1`). [config/test.exs](../config/test.exs) is unchanged — it runs `Ecto.Adapters.SQL.Sandbox` and `max_cases: 1` (D-033) already serialises it. SQLite stays; nothing else about D-003 or D-012 changes.

**Why:** SQLite permits one write transaction across the whole database file (D-033), and `default_transaction_mode: :immediate` takes that lock at `BEGIN`. With five pooled connections, five processes race `BEGIN IMMEDIATE` simultaneously, and SQLite's busy handler is a documented-unfair sleep-and-retry loop rather than a queue — so contenders collide, back off, collide again, and a loser can burn the entire 5,000 ms `busy_timeout` waiting for a lock the winner holds for 0.3 ms. Extra pool slots do not merely fail to help writes, as D-013's consequences state; they **manufacture** the contention.

Measured on a real pool at production's settings (WAL, `busy_timeout: 5_000`, `:immediate`), 15 voters submitting inside a 2-second window — the product's stated worst case, a deadline burst:

| pool_size | p50 | p95 | max |
|---|---|---|---|
| 5 | 32 ms | 25,762 ms | 38,888 ms |
| 1 | 3.6 ms | 10.6 ms | 127.0 ms |

At 64 genuinely simultaneous ballots, `pool_size: 5` refused 56 of 256 outright; `pool_size: 1` completed all 256 at p50 74 ms, max 129 ms. Phase timing localises 100% of the delay to `BEGIN IMMEDIATE` — every pre-transaction read stays sub-millisecond — which confirms D-034's short transaction was never the problem. `synchronous: :off` changed nothing, so it is contention, not disk.

The latency is not merely cosmetic: `commit_ballot/3` re-checks the deadline inside the transaction, so a ballot delayed past the deadline by the convoy is refused with `{:error, :deadline_passed}` and lost, and D-036 forbids recasting.

**Alternatives rejected:**
- *Raise `busy_timeout`.* Lengthens the convoy rather than dissolving it — the same trap D-033 already names.
- *Raise `pool_size` instead.* Tried: 10 and 20 both measured worse than 1 by an order of magnitude, and the sweep is non-monotonic, which is the signature of a convoy rather than a queue.
- *Separate read and write pools (writes on a pool of 1).* The principled answer at larger scale, and unnecessary here: with one connection, 16 concurrent readers reloading a results screen measured p50 7.2 ms / max 15.6 ms while 8 ballots landed — better than `pool_size: 5`'s 5,431 ms read tail. Revisit only if reads ever become the bottleneck.
- *Postgres.* Reopens D-003 to solve a problem that a one-line change removes.

**Consequences:**
- D-013's consequence line "`POOL_SIZE` (default `5`) buys concurrent *readers* only; extra pool slots cannot parallelise writes" is **wrong as written** and must be corrected in place: extra slots actively degrade both reads and writes under a burst.
- Writes are now serialised by DBConnection's fair FIFO queue instead of by SQLite's unfair busy handler. `{:error, {:database_busy, _}}` becomes correspondingly rare; the rescues and D-034's retry stay as the backstop.
- Any future code that holds a connection while awaiting another process that needs one would deadlock rather than merely queue. `Consensus.LinkPreview.fetch/1` — the only `start_async` caller — does no database work, and Ecto reuses the same connection inside `Repo.transact/1`, so nothing today is affected. This is a new rule to check when adding `start_async` or `Task.async` around database work.
- Measured on this Mac, not on Fly (open-questions F-2). The convoy mechanism is contention, not I/O, so it will reproduce on Fly; the absolute latencies will be higher.
