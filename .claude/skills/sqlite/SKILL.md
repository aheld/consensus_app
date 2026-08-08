---
name: sqlite
description: Operating SQLite via ecto_sqlite3/exqlite in the Consensus Phoenix app — where consensus_dev.db and the MIX_TEST_PARTITION-suffixed consensus_test.db live, the DATABASE_PATH volume file in production, the WAL/busy_timeout/default_transaction_mode settings in config/dev.exs, config/test.exs and config/runtime.exs, the single-writer constraint, why "** (Exqlite.Error) database is locked"/"Database busy" happens, and why the test suite runs one case at a time (`max_cases: 1`) instead of relying on concurrency being safe. Use this when writing or debugging an Ecto migration that SQLite rejects (ALTER COLUMN, ADD CONSTRAINT, adding a NOT NULL column), naming a CHECK constraint so check_constraint/3 matches it, inspecting or querying the database with the sqlite3 CLI or from IEx, resetting or backing up the database, diagnosing locked/busy errors or flaky tests, or reasoning about how the single Fly machine and its mounted volume constrain scaling.
---

# SQLite in Consensus

Consensus runs `ecto_sqlite3` 0.24 on `exqlite` 0.39 against `Ecto.Adapters.SQLite3`.
There is exactly one repo, `Consensus.Repo` (`lib/consensus/repo.ex`), and it is a plain
`use Ecto.Repo, otp_app: :consensus, adapter: Ecto.Adapters.SQLite3`.

SQLite is not "Postgres with a smaller footprint". Three things follow from the file-based
design and drive everything below:

1. **One writer at a time, process-wide and machine-wide.** Readers are concurrent under WAL; writers are not.
2. **The database is a file on a disk**, so "where is that disk" is a deployment question, not a config question.
3. **`ALTER TABLE` is nearly absent.** Most schema changes that are one line in Postgres need a table rebuild here.

## When NOT to use this

Storage layer only. Not the place for: Fly deploys, `fly.toml`, secrets, volume provisioning,
production log reading → **`fly-io`** skill (this skill covers only the SQLite-correctness
constraints Fly config must respect). Mix/ExUnit/changeset mechanics that are not
SQLite-specific → **`elixir`** skill. Session/vote data modelling → `docs/PRD.md` and
`docs/decisions.md`.

## Where the database files live

Read from `config/dev.exs:4-11`, `config/test.exs:11-17`, `config/runtime.exs:44-60`. Do not
guess — and re-check the line numbers, config files drift.

| Env | Config key | Resolved path | Notes |
|---|---|---|---|
| dev | `config/dev.exs` | `<repo root>/consensus_dev.db` | `Path.expand("../consensus_dev.db", __DIR__)` from `config/` |
| test | `config/test.exs` | `<repo root>/consensus_test<PARTITION>.db` | `Path.expand("../consensus_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__)`; `pool: Ecto.Adapters.SQL.Sandbox`, `pool_size: 5` |
| prod | `config/runtime.exs` | `System.get_env("DATABASE_PATH")` | **raises at boot if unset**; `POOL_SIZE` env, default `5` |

**`MIX_TEST_PARTITION` is interpolated straight into the test filename**, so
`MIX_TEST_PARTITION=7 mix test` works against `consensus_test7.db` and unset gives plain
`consensus_test.db`. Use it whenever another process might be running the suite in this
same checkout — it is the cheap way to avoid two `mix test` runs fighting over one file.
`export` it once and **every** mix command picks it up, `mix precommit` included (verified
2026-08-08: from a clean slate, `MIX_TEST_PARTITION=6 mix precommit` created only
`consensus_test6.db{,-shm,-wal}`). Clean up your `consensus_test<N>.db*` afterwards.

Each database is really three files: `X.db`, `X.db-wal`, `X.db-shm`. `.gitignore` lines 39–40
(`*.db`, `*.db-*`) cover all three. Never commit any of them, and never copy only the `.db`
file when a `-wal` sibling exists and is non-empty — you will silently lose the tail of the
write log.

In production the path must point **inside the mounted volume** (`/data/...`), not at the
container filesystem. A machine's root filesystem is discarded on every deploy.

## Pragmas: what this repo sets, and what the adapter defaults

**This repo does set pragmas — in all three environments.** They are not left to the
adapter. Read the real lines before changing anything:

| Config | Sets |
|---|---|
| `config/dev.exs:4-18` | `journal_mode: :wal`, `busy_timeout: 5_000`, **`default_transaction_mode: :immediate`**, plus `stacktrace: true`, `show_sensitive_data_on_connection_error: true` |
| `config/test.exs:11-25` | `busy_timeout: 5_000`, `journal_mode: :wal`, `pool: Ecto.Adapters.SQL.Sandbox`, `pool_size: 5` — **no** `default_transaction_mode` (the sandbox opens the transaction, not us; see D-033) |
| `config/runtime.exs:51-67` (`:prod` only) | `journal_mode: :wal`, `busy_timeout: 5_000`, **`default_transaction_mode: :immediate`**, `pool_size:` from `POOL_SIZE` (default 5); the `DATABASE_PATH` raise is at `:44-48` |

**`default_transaction_mode: :immediate` in dev and prod is D-033, not the original D-013 pair.** ecto_sqlite3's default is `:deferred` — a transaction takes no write lock at `BEGIN` and only asks for one on its first write. If another writer already holds the lock by then, SQLite cannot make this connection wait (it already holds a read snapshot, and blocking could deadlock the pair), so it returns `SQLITE_BUSY` **immediately** and the `busy_timeout` handler never runs. `:immediate` takes the write lock up front, at `BEGIN`, which is the state the busy handler *can* wait in — so two organizers writing at once queue for up to 5s instead of one 500ing. `config/test.exs` deliberately does not set it: every test transaction is opened by `Ecto.Adapters.SQL.Sandbox`, not by application code, so this repo's own setting has nothing to attach to there — see "The test suite runs one case at a time" below for why that distinction matters more than it sounds like it should.

**The busy timeout is `5_000` ms everywhere, not the exqlite default of 2000.** Each
config file carries a comment saying why: dev matches prod so "database is locked" cannot
be a production-only surprise, and test wants concurrent async tests to *wait* rather than
fail. If you quote a number, quote 5000.

`journal_mode: :wal` in dev and prod is stated explicitly even though it is already the
ecto_sqlite3 default (`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:80`) — the runtime
comment says it is written out because it is load-bearing on a single Fly machine. Test
does not set it and inherits the same value.

Measured on a live `Consensus.Repo` connection (`MIX_TEST_PARTITION=7 mix test`, then
`Ecto.Adapters.SQL.query!(Repo, "PRAGMA <name>", []).rows`):

| Pragma | Effective value | Source |
|---|---|---|
| `journal_mode` | `[["wal"]]` | config + ecto_sqlite3 default (SQLite's own default is `delete`) |
| `foreign_keys` | `[[1]]` (on) | ecto_sqlite3 default (SQLite's own default is **off**) |
| `busy_timeout` | configured 5000 — but `PRAGMA busy_timeout` **reports `[[0]]`**, see below | `config/*.exs` |
| `cache_size` | `[[-64000]]` (64 MB) | ecto_sqlite3 default |
| `temp_store` | `[[2]]` (memory) | ecto_sqlite3 default |
| `synchronous` | `[[1]]` (normal) | correct pairing with WAL |
| `wal_autocheckpoint` | `[[1000]]` pages | default |
| `default_transaction_mode` | `:deferred` (in test — `config/test.exs` does not set this key) | ecto_sqlite3 default. **Dev and prod override it to `:immediate`** (D-033) — see the pragma table above. |

**`PRAGMA busy_timeout` returning `0` is not a bug and not a misconfiguration**, and in
this repo it is emphatically not evidence that the timeout is unset — `config/test.exs`
sets 5000 and the pragma still reports 0. `exqlite` installs its own busy handler through
the `Exqlite.Sqlite3.set_busy_timeout/2` NIF rather than the pragma, with the reason in a
comment at `deps/exqlite/lib/exqlite/connection.ex:537-540`: *"Use our NIF instead of
PRAGMA busy_timeout, because PRAGMA internally calls sqlite3_busy_timeout() which destroys
our custom busy handler."* The `:busy_timeout` repo option feeds that NIF via
`Exqlite.Pragma.busy_timeout/1` (`deps/exqlite/lib/exqlite/pragma.ex:8-10`), whose default
is 2000. There is no way to read the effective value back out of SQLite; read the config.

### Why WAL and busy_timeout matter here

Without WAL, a single reader blocks every writer for the duration of its read. Consensus is a
LiveView app: every connected voter holds a process that reads on every broadcast. Under
`journal_mode = delete` a tally read would serialize against the vote write that triggered it.
WAL lets readers proceed against a consistent snapshot while one writer appends to the log.

`busy_timeout` turns a *transient* lock conflict into a *wait* instead of an error. At 0, a
second writer fails instantly with `** (Exqlite.Error) database is locked`. At 5000 ms it
retries for five seconds first — enough for every normal transaction in this app, and the
reason the async test suite is not flaky.

### Foreign keys are on, and one context function leans on that

`PRAGMA foreign_keys` is `[[1]]` on every Ecto connection — re-verified 2026-08-08 against
`MIX_TEST_PARTITION=3`. That is `ecto_sqlite3`'s default, **not** SQLite's, whose own default
is off; nothing in `config/` sets it.

It is load-bearing rather than incidental, because `Consensus.Accounts.delete_user/2` (D-015 —
the account-recovery lever on a deployment with no mail provider) does a plain `Repo.delete/1`
and lets the referential actions do the rest:

| Reference | Declared as | On delete |
|---|---|---|
| `users_tokens.user_id` | `references(:users, on_delete: :delete_all)` in `20260808033720_create_users_auth_tables.exs` | rows cascade away |
| `activity_groups.organizer_id` | `references(:users, on_delete: :delete_all)` in `20260808183423_create_activity_groups.exs` | **every group that user organizes is deleted with them** — and `activities.group_id` is itself `on_delete: :delete_all` against `activity_groups`, so deleting an organizer cascades two levels deep to that organizer's whole pool of options. `Consensus.Accounts.delete_user/2` refuses to delete an administrator, but an ordinary organizer has no such guard — deleting one is destructive to their groups by design, not an oversight. |
| `activities.added_by_id` | `references(:users, on_delete: :nilify_all)` in the same migration | nulled, the activity survives — whoever pasted a link is not load-bearing the way the group's owner is |

The `home_page.updated_by_id` `ON DELETE SET NULL` reference this table used to describe is
gone — `home_page` was dropped in `20260808183755_drop_home_page.exs` (D-027).

Turn foreign keys off — in a table-rebuild migration, or by testing the behaviour from a
`sqlite3` CLI session where they default to off — and none of this fires. Deleting a user would
leave orphaned session tokens that still authenticate, and orphaned groups/activities pointing at
nothing. If you reproduce a deletion by hand, `PRAGMA foreign_keys = ON;` first.

## The single-writer constraint and what it means for deployment

SQLite's write lock is per-file. Two OS processes — on the same machine or on two machines
sharing nothing — cannot coordinate. Consequences that are **correctness** issues, not cost
tuning:

- **Exactly one Fly machine.** Two machines cannot share a volume. Two machines each with
  their own volume is two divergent databases, not a cluster. `fly scale count 2` corrupts
  the product's state, it does not scale it.
- **No multi-region.** Same reason.
- **`auto_stop_machines` / `min_machines_running`** are a correctness concern: a machine that
  stops mid-checkpoint, or a cold start racing a deploy, both touch the same file. Keep at
  least one machine running. Details in the `fly-io` skill.
- **Migrations must not run in a Fly `[deploy] release_command`.** The release machine has no
  volume mounted, so `DATABASE_PATH` would point at ephemeral disk — the migration would
  "succeed" against a throwaway file and the real database would stay unmigrated.
- **Migrations run at application boot instead.** `lib/consensus/application.ex` starts
  `{Ecto.Migrator, repos: Application.fetch_env!(:consensus, :ecto_repos), skip: skip_migrations?()}`
  as a supervision child, followed immediately by `{Consensus.Seeds, skip: skip_seeds?()}`.
  Both run synchronously during supervisor init and return `:ignore`, so the endpoint only
  starts once the schema is current. `skip_migrations?/0` is `System.get_env("RELEASE_NAME") == nil`,
  i.e. migrations run in a release and are skipped under `mix`.

One more reason the single machine is load-bearing: `Ecto.Adapters.SQLite3.lock_for_migrations/3`
is a **no-op** (`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:320`). There is no advisory
migration lock. Two nodes booting at once would both try to migrate.

## Migrations: what SQLite refuses, and the workaround

`mix ecto.gen.migration <name>` writes to `priv/repo/migrations/`. Check status with
`mix ecto.migrations`, and say which environment you mean — dev and test are different
files and are routinely at different versions:

```bash
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.migrations
```

```
Repo: Consensus.Repo

  Status    Migration ID    Migration Name
--------------------------------------------------
  up        20260808033720  create_users_auth_tables
  up        20260808040000  create_home_page
  up        20260808183423  create_activity_groups
  up        20260808183755  drop_home_page
```

Four migrations, that is the whole schema — `home_page` is created in the second and dropped
in the fourth (D-027; the admin-editable home page is gone, see "The home-page singleton" note
below for what that migration's `down/0` teaches). The tables that actually exist today are
`users`, `users_tokens`, `activity_groups`, `activities`, `schema_migrations`; the indexes are
`users_email_index`, `users_username_index`, `users_tokens_user_id_index`,
`users_tokens_context_token_index`, `activity_groups_slug_index` (unique),
`activity_groups_organizer_id_index`, `activities_group_id_index` and
`activities_added_by_id_index`. `home_page` and its `home_page_updated_by_id_index` are gone;
if you see either named in an older note, it is stale.

Plain `mix ecto.migrations` reports the **dev** database, and it will print
`** (Exqlite.Error) database is locked` and then `down` for everything if another process
holds `consensus_dev.db` — that is a lock error being reported as an empty schema, not an
unmigrated database. Rerun once the other process is gone before you believe it.

### The four that raise

Each of these raises at *DDL-generation* time (an `ArgumentError`, before any SQL is sent),
so it fails fast and identically in every environment.

| You wrote | Exact error | Do this instead |
|---|---|---|
| `modify :col, :type` | `ALTER COLUMN not supported by SQLite3` | table rebuild (below) |
| `create constraint(:t, :n, check: "...")` | `SQLite3 does not support ALTER TABLE ADD CONSTRAINT.` | put a named CHECK inside `CREATE TABLE` (below) |
| `drop constraint(:t, :n)` | `SQLite3 does not support ALTER TABLE DROP CONSTRAINT.` | table rebuild |
| `create index(..., concurrently: true)` | `` `concurrently` is not supported with SQLite3 `` | drop the option; SQLite index builds are not online anyway |

`using:`, `include:`, `only:` and `nulls_distinct:` on an index raise the same way.

### CHECK constraints: inside `CREATE TABLE`, and always named

Ecto's table-level `create constraint(...)` compiles to `ALTER TABLE ... ADD CONSTRAINT`
and always raises, so a CHECK has to be part of the `CREATE TABLE`. Two routes.

**What this repo actually does** — `priv/repo/migrations/20260808040000_create_home_page.exs`
writes the whole statement as literal SQL through `execute/2`, with an explicit `down`:

```elixir
def change do
  execute(
    """
    CREATE TABLE "home_page" (
      "id" INTEGER PRIMARY KEY
        CONSTRAINT "home_page_is_a_singleton" CHECK ("id" = 1),
      "message" TEXT NOT NULL,
      "updated_by_id" INTEGER
        CONSTRAINT "home_page_updated_by_id_fkey"
        REFERENCES "users"("id") ON DELETE SET NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """,
    """
    DROP TABLE "home_page"
    """
  )

  create index(:home_page, [:updated_by_id])
end
```

**The alternative** — the adapter also reads a `:check` option off a column definition
(`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3/connection.ex:1656-1669`) and inlines it:

```elixir
add :id, :integer, primary_key: true,
  check: %{name: "home_page_is_a_singleton", expr: "id = 1"}
```

The `%{name: ..., expr: ...}` map shape is **adapter-specific to ecto_sqlite3** and is not
portable Ecto. Note it in a comment wherever you use it.

**Name the constraint, whichever route you take.** SQLite reports the failing constraint by
whatever the DDL called it, and `ecto_sqlite3` passes that string straight through as
`[check: name]` (`connection.ex:156-160`), which is what
`Ecto.Changeset.check_constraint/3`'s `name:` has to match. An anonymous column CHECK is
reported under the **column** name instead — verified on SQLite 3.51.0:

```
"id" INTEGER PRIMARY KEY CHECK ("id" = 1)
  → CHECK constraint failed: id
"id" INTEGER PRIMARY KEY CONSTRAINT "home_page_is_a_singleton" CHECK ("id" = 1)
  → CHECK constraint failed: home_page_is_a_singleton
```

The changeset half of this example is now history: `Consensus.Content` and
`Consensus.Content.HomePage` were deleted in D-027 along with the `home_page` table, so there is
no changeset left declaring `check_constraint(:id, name: :home_page_is_a_singleton)` in `lib/`.
The migration above is still on disk exactly as written — migrations are never deleted, only
superseded by a later one — and it is still the worked example for "name the CHECK, and
`ecto_sqlite3` passes that name straight through", which is the transferable lesson. If a future
table needs a singleton-row CHECK again, copy the DDL shape, not the module name.

### A `down/0` with `Ecto.Migration.constraint/3` compiles, and only fails at rollback

`priv/repo/migrations/20260808183755_drop_home_page.exs` (the migration that actually removes
`home_page`, D-027) is the second worked example, for the opposite direction: writing a `down/0`
that recreates a CHECK-bearing table. The DSL form —

```elixir
def down do
  create table(:home_page) do
    add :id, :integer, primary_key: true
    add :message, :string, null: false
    # ...
  end

  create constraint(:home_page, :home_page_is_a_singleton, check: "id = 1")
end
```

— **type-checks and compiles cleanly**, because `Ecto.Migration.constraint/3` is ordinary,
well-formed Ecto. It only raises `SQLite3 does not support ALTER TABLE ADD CONSTRAINT.` the
moment something actually runs this `down/0` — i.e. under a real rollback
(`Consensus.Release.rollback/2`, or `Ecto.Migrator.run(&1, :down, ...)` the way CI's "boot twice
on one volume" step does it). `mix ecto.migrate` never touches `down/0` at all, so a migration
can sit in the repo, fully compiled and merged, with a `down/0` that has never once executed.
That is exactly the gap `test/consensus/release_test.exs` closes — it calls
`Release.rollback/2` against a throwaway repo and asserts `home_page` comes back, which is the
only thing in the suite that actually runs this `down/0`.

The fix is the same rule as the `up`: write the whole `CREATE TABLE` as literal SQL through
`execute/2`, CHECK and all, the way `20260808040000_create_home_page.exs` does. That is what
`20260808183755_drop_home_page.exs`'s real `down/0` does today:

```elixir
def up do
  drop index(:home_page, [:updated_by_id])
  drop table(:home_page)
end

def down do
  execute("""
  CREATE TABLE "home_page" (
    "id" INTEGER PRIMARY KEY
      CONSTRAINT "home_page_is_a_singleton" CHECK ("id" = 1),
    "message" TEXT NOT NULL,
    "updated_by_id" INTEGER
      CONSTRAINT "home_page_updated_by_id_fkey"
      REFERENCES "users"("id") ON DELETE SET NULL,
    "inserted_at" TEXT NOT NULL,
    "updated_at" TEXT NOT NULL
  )
  """)

  create index(:home_page, [:updated_by_id])
end
```

Note this `down/0` recreates the *schema*, not the *data* — there is no copy of whatever message
was stored, so a rollback lands on an empty singleton row, not the one that existed before the
table was dropped.

### Adding a NOT NULL column — the trap that only fires in production

SQLite permits `ALTER TABLE ... ADD COLUMN x NOT NULL` **only when the table has zero rows**.
Dev and test tables are usually empty, so the migration passes locally and then:

```
** (Exqlite.Error) Cannot add a NOT NULL column with default value NULL
```

on the machine that has real data. Two safe forms:

```elixir
# 1. NOT NULL with a constant default — always legal
add :vote_count, :integer, null: false, default: 0

# 2. Nullable, backfill, then rebuild if the constraint truly must exist
def up do
  alter table(:sessions) do
    add :slug, :string          # nullable
  end
  execute "UPDATE sessions SET slug = 'legacy-' || id WHERE slug IS NULL"
  create unique_index(:sessions, [:slug])
end
```

`:utc_datetime` / `:naive_datetime` columns are a special case: the adapter **silently drops
your `null: false`** when adding one (`connection.ex:1602-1620`), because SQLite requires a
constant default and `CURRENT_TIMESTAMP` is not constant. Do not assume the column is NOT NULL
just because you wrote it.

### `DROP COLUMN` and `RENAME COLUMN`

Both are generated (`ALTER TABLE t DROP COLUMN c`, `ALTER TABLE t RENAME COLUMN a TO b`) and
both work on modern SQLite. The local CLI is 3.51 and the Docker runtime image is current, so
version is not a concern here. But SQLite still refuses `DROP COLUMN` when the column is
referenced by an index, a partial-index `WHERE`, a view, a trigger, or a CHECK expression —
drop the dependent object in the same migration first.

### The table-rebuild recipe (for `modify`, dropping a constraint, changing a FK)

There is no Ecto sugar for this. Write raw SQL in the migration:

```elixir
def up do
  execute "PRAGMA foreign_keys = OFF"

  execute """
  CREATE TABLE sessions_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slug TEXT NOT NULL,
    closes_at TEXT NOT NULL,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """

  execute "INSERT INTO sessions_new SELECT id, slug, closes_at, inserted_at, updated_at FROM sessions"
  execute "DROP TABLE sessions"
  execute "ALTER TABLE sessions_new RENAME TO sessions"
  execute "CREATE UNIQUE INDEX sessions_slug_index ON sessions (slug)"

  execute "PRAGMA foreign_key_check"
  execute "PRAGMA foreign_keys = ON"
end
```

Rules: recreate **every** index and trigger the old table had (`DROP TABLE` takes them with
it); run `PRAGMA foreign_key_check` before re-enabling; and pair it with a real `down/0` or
`def down, do: :ok` — `change/0` cannot infer the inverse.

**Before the app ships, prefer editing the original migration and resetting.** That is what
`create_users_auth_tables.exs` already does: `username` and `is_admin` are folded into the
initial migration with a comment explaining why, rather than added later. Pre-deploy, `mix
ecto.reset` is cheaper and cleaner than a rebuild migration.

### Datetimes are TEXT

`:datetime_type` defaults to `:iso8601`, so `inserted_at` is stored as
`"2026-08-08T03:40:49"` in a `TEXT` column. String comparison happens to sort correctly for
this format, but raw SQL that does date arithmetic must go through SQLite's `datetime()` /
`julianday()` functions, not integer math. Ecto handles the round-trip for you; only raw
`execute`/`query!` needs care.

## Inspecting the database

### sqlite3 CLI — always against a copy

The dev database is open, in WAL mode, with a live connection pool. Read-only queries against
the live file are usually fine, but anything that takes a write lock (including some `PRAGMA`s
and `VACUUM`) will fight the running server. **Copy first.** Copy all three files:

```bash
cd /Users/aheld/Projects/consensus_app
cp consensus_dev.db      /tmp/inspect.db
cp consensus_dev.db-wal  /tmp/inspect.db-wal   # may not exist; that's fine
cp consensus_dev.db-shm  /tmp/inspect.db-shm

sqlite3 /tmp/inspect.db ".tables"    # activities  activity_groups  schema_migrations  users  users_tokens
sqlite3 /tmp/inspect.db ".schema users"
sqlite3 -header -box /tmp/inspect.db "select * from schema_migrations;"
sqlite3 /tmp/inspect.db "select name, tbl_name from sqlite_master where type='index';"
sqlite3 /tmp/inspect.db "PRAGMA integrity_check; PRAGMA foreign_key_check;"
```

Interactive: `sqlite3 /tmp/inspect.db`, then `.headers on`, `.mode box`,
`PRAGMA foreign_keys = ON;`, `.quit`.

**The CLI does not share Ecto's pragmas.** A fresh `sqlite3` session reports
`PRAGMA foreign_keys` → `0` and `PRAGMA busy_timeout` → `0`. If you are reproducing an FK
behaviour you saw from the app, turn foreign keys on explicitly or you will get the wrong
answer.

### From IEx

```elixir
iex -S mix phx.server
```

```elixir
# raw SQL, returns %Exqlite.Result{columns: [...], rows: [[...]]}
Ecto.Adapters.SQL.query!(Consensus.Repo, "select count(*) from users", [])

# what the adapter actually negotiated on this connection
Ecto.Adapters.SQL.query!(Consensus.Repo, "PRAGMA journal_mode", []).rows   #=> [["wal"]]
Ecto.Adapters.SQL.query!(Consensus.Repo, "PRAGMA foreign_keys", []).rows   #=> [[1]]

Ecto.Adapters.SQL.query!(Consensus.Repo, "select name from sqlite_master where type='table'", []).rows

# see the SQL Ecto will emit, without running it
Consensus.Repo.to_sql(:all, Consensus.Accounts.User)
```

`Ecto.Adapters.SQL.explain(Consensus.Repo, :all, query)` works too, though SQLite's
`EXPLAIN QUERY PLAN` output is far terser than Postgres's. In production, reach IEx through
the release rather than `mix` — see the `fly-io` skill.

`mix ecto.dump` / `mix ecto.load` shell out to the `sqlite3` binary
(`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:325-347`) and fail with a "shell utility"
error if it is not on `PATH`. On this Mac it is `/usr/bin/sqlite3` (3.51.0).

## Resetting and seeding in dev

```bash
mix ecto.reset     # ecto.drop + ecto.create + ecto.migrate + run priv/repo/seeds.exs
mix ecto.migrate
mix ecto.rollback  # one step; -n N for more
```

`ecto.drop` will fail if the dev server holds the file — stop `mix phx.server` first.

`ecto.reset` drops `consensus_dev.db`. **Never run it when someone else may be working in
this checkout** — `mix ecto.migrations` reporting "database is locked" is your sign that
another process holds the file.

Seeding is defined once, in `Consensus.Seeds`, and reached three ways: `priv/repo/seeds.exs`
under `mix ecto.setup`, the `{Consensus.Seeds, skip: skip_seeds?()}` supervision child at
release boot, and `Consensus.Release.seed/0` for running it by hand on a live machine.
`skip_seeds?/0` honours `config :consensus, :seed_on_boot`, and `config/test.exs:21` sets it
to `false` so the suite is never seeded behind ExUnit's back — several `count_users/0` and
`list_users/0` assertions depend on starting from zero rows.

`run!/0` is idempotent. It creates the bootstrap admin only when
`Consensus.Accounts.count_admins()` is zero — the gate is "does this database have any
administrator?", not "does the user `aheld` exist?" — so renaming or re-emailing the seeded
account cannot make the next boot look like a first boot.

## Tests: the sandbox, `async: true`, and why the suite runs one case at a time (D-033)

`config/test.exs` sets `pool: Ecto.Adapters.SQL.Sandbox` and `pool_size: 5`;
`test/support/data_case.ex` / `conn_case.ex` call
`Ecto.Adapters.SQL.Sandbox.start_owner!(Consensus.Repo, shared: not tags[:async])`;
`test/test_helper.exs` puts the repo in `:manual` mode **and calls `ExUnit.start(max_cases: 1)`**
— read that file's own comment before assuming anything below, it is the authority.

**`async: true` still means what it always meant — own connection, own transaction, rolled back
at exit — but it no longer means "runs at the same time as its neighbours", and that distinction
is the whole of D-033.** The suite used to run at ExUnit's default `max_cases: 20`, on the
reasoning that the sandbox's per-case transaction plus `busy_timeout: 5_000` made concurrent
writers safe. **That reasoning was incomplete, and once the suite grew past ~330 tests it started
failing for real:**

- SQLite permits exactly **one write transaction across the whole database file.** The sandbox
  holds each test's transaction open for the *entire test*, so two `async: true` cases that both
  touch the database are two open transactions on one file by construction — not a rare
  coincidence, the normal case.
- `busy_timeout` is **never consulted** in that collision, which is the part the old wording
  missed. A connection that is already inside a transaction and asks to *upgrade* to a write
  cannot be made to wait — blocking here could deadlock the pair, since this connection already
  holds a read snapshot — so SQLite returns `SQLITE_BUSY` **immediately** instead. The busy
  handler that `busy_timeout: 5_000` installs simply never runs. That is why the failure looked
  so strange: `** (Exqlite.Error) Database busy` on an ordinary `INSERT INTO users` inside a
  `setup` block, in whichever case happened to lose the race, in a suite that still finished in
  a couple of seconds — the classic shape of "not a tuning problem".
- Measured at 430 tests (2026-08-08): **~50 failures a run at the default `max_cases: 20`**,
  still **~46 at `--max-cases 2`**, **zero at `--max-cases 1`**. Marking every LiveView test
  `async: false` was tried first and cut it to ~27 failures — a partial fix that invites getting
  called "done" — and the rest were in `Consensus.ActivitiesTest`, an ordinary `DataCase`, which
  is what proved the problem was never LiveView-specific, only correlated with how long a case
  holds its transaction open. `journal_mode: :wal` and `default_transaction_mode: :immediate`
  were also tried in `config/test.exs` first, and **neither helped** — the transaction in
  question is opened by the sandbox, not by application code, so a repo-level pragma has nothing
  to attach to.

**The fix is `test/test_helper.exs`'s `ExUnit.start(max_cases: 1)`.** The suite runs its cases
one at a time regardless of `async:`, which removes the collision at its root rather than tuning
around it. `async: true` is still correct to set on a case — it still buys the sandbox isolation,
own connection and own rolled-back transaction — it just does not buy concurrency here, and
pretending otherwise is what the previous version of this skill got wrong. At ~2.6s for 431
tests serially, there was nothing worth buying back by staying concurrent.

**The same bug exists in production, with a different fix.** `Consensus.Repo`'s own
`Repo.transact/1` calls — `Accounts.set_admin/3`, `Accounts.delete_user/2`,
`Activities.delete_activity/2`, `Activities.reorder_activities/3` — open deferred transactions
too, by the ecto_sqlite3 default. Two organizers writing at the same moment on the single
machine would hit the identical immediate `SQLITE_BUSY`, surfacing as a 500 instead of a short
wait. `config/dev.exs` and the `:prod` block of `config/runtime.exs` now set
`default_transaction_mode: :immediate`, which takes the write lock at `BEGIN` rather than on the
first write — the state the busy handler *can* wait in — so the second writer queues for up to
five seconds instead of failing outright. `config/test.exs` cannot use the same fix, because it
is the sandbox's transaction that is deferred, not ours.

`test/consensus/activities_test.exs` is `async: true` and does real database work — inserts,
updates, deletes, a `Repo.transact/1` reorder — and passes, because the suite no longer runs
concurrently. It is the file to copy for a new context test.

**What forces `async: false` today is global mutable state or DDL — the same rule as before,
just re-derived against the current files, because `test/consensus/content_test.exs` (the file
this skill used to point at) is deleted along with `Consensus.Content` (D-027):**

| File | Why |
|---|---|
| `test/consensus/seeds_test.exs` | `System.put_env` / `System.delete_env` on `ADMIN_USERNAME`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` |
| `test/consensus/accounts/user_notifier_test.exs` | `Application.put_env(:consensus, Consensus.Mailer, ...)` to swap the Swoosh adapter |
| `test/consensus/application_test.exs`, `test/consensus/boot_check_test.exs` | `RELEASE_NAME`, application env, real directories and permissions; no repo |
| `test/consensus/release_test.exs` | starts its own throwaway repo against a tmp-dir database |
| `test/consensus/link_preview_test.exs` | the `Consensus.LinkPreview.Cache` ETS table is one named, process-global table (a real supervised child, not started per test), and some cases override `Application.put_env(:consensus, Consensus.LinkPreview, cache_error_ttl_ms: ...)` to make an expiry observable in milliseconds |
| `test/consensus_web/controllers/health_controller_test.exs` | **DDL.** See below. |

**The DDL rule is the SQLite-specific one, and it still applies even though the suite no longer
runs concurrently.** `health_controller_test.exs` proves `/health` can fail by running
`ALTER TABLE … RENAME` inside the sandbox transaction. SQLite needs an **exclusive lock on the
whole database file** for schema changes, and the sandbox cannot isolate that from a *shared*
connection (the ordinary, non-`async` case) still holding a read transaction — so this module is
pinned `async: false` on that basis independent of `max_cases`. The DDL still rolls back with the
transaction. **Any test that issues DDL must be `async: false`**; inserts, updates and deletes
remain perfectly safe async.

Explicit `async: true` today: `test/consensus/activities_test.exs`,
`test/consensus/deadlines_test.exs` (pure, `use ExUnit.Case` — no database),
`test/consensus/deploy_config_test.exs` (reads `fly.toml` as text — no database),
`test/consensus_web/router_test.exs` (no database), `test/consensus_web/journey_test.exs`,
`test/consensus_web/live/group_live/new_test.exs`,
`test/consensus_web/live/group_live/options_test.exs`,
`test/consensus_web/live/home_live_test.exs`, and the two controller tests
`error_html_test.exs` / `error_json_test.exs`. Everything else — `accounts_test.exs`,
`user_auth_test.exs`, `user_session_controller_test.exs`, `admin_live/users_test.exs`,
`group_live/review_test.exs`, `group_live/share_test.exs`, and every `user_live/*` test — carries
no `async:` flag, which defaults to `false`: generator inheritance, not a considered decision.
Promoting one is still fair game — it buys isolation hygiene even without concurrency — prove it
with `--repeat-until-failure 20` first. Re-derive this list with
`grep -rn "use Consensus.DataCase\|use ConsensusWeb.ConnCase\|use ExUnit.Case" test` rather than
trusting it verbatim; several agents add test files to this tree.

The `test` alias runs `ecto.create --quiet` and `ecto.migrate --quiet` first, so a fresh
checkout needs only `mix test`.

## Backups

- **Fly volume snapshots** are the baseline: daily, automatic, retained per the volume's
  setting. Restoring means creating a new volume from a snapshot and pointing the machine at
  it — a restore is a small outage, not a hot failover. Commands live in the `fly-io` skill.
- **`VACUUM INTO`** is the correct way to take a consistent copy of a live database. It is a
  single statement, it is safe while the app is running, and it produces a clean file with the
  WAL already folded in:

  ```elixir
  Ecto.Adapters.SQL.query!(Consensus.Repo, "VACUUM INTO '/data/backup-2026-08-08.db'", [])
  ```

  Never `cp` a live `.db` on its own — see the WAL note above.
- **Litestream** (continuous WAL replication to object storage) is the option if
  snapshot-granularity RPO is not good enough. It runs as a sidecar in the container and is a
  real change to the Dockerfile and boot sequence. It is **not currently set up**; adopting it
  is a decision to log in `docs/decisions.md`, not something to add silently.

## Common failure modes

**`** (Exqlite.Error) database is locked` / `** (Exqlite.Error) Database busy`**
Both phrasings show up in this repo's own comments for the same underlying condition — the
literal text `exqlite` throws is `"Database busy"` (`deps/exqlite/lib/exqlite/sqlite3.ex:396`,
mapping SQLite's `SQLITE_BUSY`) — so treat them as one failure mode, not two.

**There are two different mechanisms behind it, and which one you have changes the fix:**

1. **The connection was genuinely made to wait, and the wait ran out.** Another writer held the
   lock for longer than the 5 s `busy_timeout`. Causes, most to least likely: (a) **two OS
   processes on the same file** — `iex -S mix phx.server` in one terminal and `mix ecto.migrate`
   in another, or two agents sharing this checkout; (b) a long-running transaction, e.g. a
   `Repo.transact/1` that does HTTP inside it; (c) in production, more than one machine. Five
   seconds is already generous, so treat this as real contention, not a tuning problem — raising
   `busy_timeout` further just turns a fast failure into a slow one.
2. **The connection was never made to wait at all — `busy_timeout` was never consulted.** This is
   the mechanism D-033 exists to name. A connection that is already inside a transaction and
   tries to *upgrade* it to a write cannot be made to wait for another writer, because it already
   holds a read snapshot and blocking could deadlock the pair — so SQLite returns `SQLITE_BUSY`
   **immediately**, before the busy handler ever runs. This is what a deferred transaction
   (ecto_sqlite3's default `default_transaction_mode: :deferred`) does under contention, and it is
   exactly what happened when the test suite ran cases concurrently: `Ecto.Adapters.SQL.Sandbox`
   holds each test's transaction open for the whole test, so two `async: true` cases that both
   touched the database were two open deferred transactions on one file, and the second one to
   write failed instantly. **Raising `busy_timeout` cannot fix this shape at all** — it turns a
   fast failure into the identical fast failure, because the handler it configures is never
   reached. The fix is either not opening two write transactions on the file at once
   (`test/test_helper.exs`'s `ExUnit.start(max_cases: 1)`, see above) or taking the write lock at
   `BEGIN` instead of on the first write, which is what `default_transaction_mode: :immediate` in
   `config/dev.exs` and the `:prod` block of `config/runtime.exs` does for our own
   `Repo.transact/1` calls in production (D-033).

Two things it is usually *not*: it is not ordinary `async: true` test contention any more — the
suite runs one case at a time (`max_cases: 1`), so two tests cannot hold overlapping write
transactions regardless of their `async:` tags — and it is not a missing `busy_timeout` because
`PRAGMA busy_timeout` says 0 (see the pragma section — that is expected). Note that a `mix` task
hitting mechanism 1 can report it and then print misleading downstream output; `mix
ecto.migrations` prints the lock error and then lists every migration as `down`.

`Consensus.Accounts.set_admin/3` and `delete_user/2` both `rescue Exqlite.Error` into
`{:error, {:database_busy, message}}` so a caller can show something useful instead of crashing
the LiveView (D-021). `Consensus.Activities`' own `Repo.transact/1` calls —
`delete_activity/2`, `reorder_activities/3` — do **not** rescue this; a `Database busy` there
still crashes the LiveView. That gap is real, worth knowing before you touch either function, and
is not itself part of D-033 — D-033 is about why the contention happens, not about which callers
recover from it.

**`** (Exqlite.Error) Cannot add a NOT NULL column with default value NULL`**
`ALTER TABLE ... ADD COLUMN x NOT NULL` on a table that has rows. Passes on empty dev/test
tables, fails in production. Add a `default:`, or add it nullable and backfill. See above.

**`** (ArgumentError) ALTER COLUMN not supported by SQLite3`**
A `modify` inside `alter table`. Rebuild the table, or — pre-deploy — edit the original
migration and `mix ecto.reset`.

**`** (ArgumentError) SQLite3 does not support ALTER TABLE ADD CONSTRAINT.`**
`create constraint(...)`. Move the CHECK inline onto the column with
`check: %{name: ..., expr: ...}` in the `create table` block.

**`** (RuntimeError) environment variable DATABASE_PATH is missing.`**
`config/runtime.exs:44-48` raising at boot. The release has no `DATABASE_PATH`, or it is set to
a path outside the mounted volume. It must be a file inside the mount (`/data/...`).

**`** (RuntimeError) Cannot write the SQLite database (...)`**
`DATABASE_PATH` is set and either its directory or the existing file is not writable by the
release user. This is `Consensus.BootCheck.run!/0` (D-016, `lib/consensus/boot_check.ex`), which
runs *before* `Consensus.Repo` starts: it `mkdir_p`s the directory, writes-then-removes a
`.consensus-write-probe`, and then opens **the whole existing WAL set** for `:append` —
`DATABASE_PATH` *and* its `-wal` and `-shm` sidecars, skipping whichever do not exist yet. That
matters here specifically: `config/runtime.exs` pins `journal_mode: :wal`, so SQLite cannot
start without write access to all three, and a sidecar's ownership can differ from the
database's (a root `cp`/`tar`/snapshot restore preserving its own ownership is the usual cause —
running `sqlite3` as root is *not*, since SQLite fchowns a journal it creates to match the
database file's owner). The raised message names **the path that actually refused**, plus
`DATABASE_PATH`, the directory's and file's real `uid:gid` and octal mode, and the `chown` that
fixes it. It exists so that an unwritable Fly volume stops looking like a connection-pool
problem — the unguarded failure was `database_open_failed` lines followed by a
`DBConnection.ConnectionError`. At boot it is gated on `RELEASE_NAME`, so it never fires under
`mix`; **all three** `Consensus.Release` entry points — `migrate/0`, `seed/0` and `rollback/2` —
call it unconditionally, through a private `preflight!/1` that passes the repo's own configured
`:database` to `BootCheck.run!/1`. The remedy is in the `fly-io` skill.

**`<dir> is not a mount point — it is part of the container filesystem.`**
Same module, different check: the database's directory is on the same filesystem device as `/`,
so it lives in the container image and the next deploy destroys it. On Fly (`FLY_APP_NAME` set)
this **raises** and fails the deploy — the database is empty by definition at that point, so
failing costs nothing. Anywhere else it is only a `Logger.warning`, which is what lets a local
`docker run` with no `-v` still boot. `Consensus.BootCheck.on_root_filesystem?/1` is the
predicate, and it returns `false` when either path cannot be stat'd so an unknown answer never
fails a boot.

**`** (Exqlite.Error) UNIQUE constraint failed: users.email`** surfacing as a 500 instead of a
form error
The changeset is missing the matching `unique_constraint/3`. `ecto_sqlite3` maps this message
to an Ecto constraint in `to_constraints/2` (`connection.ex:137-163`) — but only if the
changeset declares one. Same for `FOREIGN KEY constraint failed` → `foreign_key_constraint/3`
and `CHECK constraint failed: <name>` → `check_constraint/3`.

**`PRAGMA busy_timeout` returns 0**
Expected, even though `config/dev.exs`, `config/test.exs` and `config/runtime.exs` all set
`busy_timeout: 5_000`. `exqlite` applies it through a NIF-installed busy handler rather than
the pragma, because issuing the pragma would destroy that handler. Not a misconfiguration;
do not "fix" it, and do not read it as proof the timeout is unset. Read the config instead.

**`PRAGMA foreign_keys` returns 0 in the sqlite3 CLI**
Expected. The CLI defaults foreign keys off; `ecto_sqlite3` defaults them on. Run
`PRAGMA foreign_keys = ON;` at the start of a CLI session if FK behaviour is what you are testing.

**`mix ecto.drop` hangs or errors with the file in use**
The dev server still holds the connection. Stop `mix phx.server`, then retry.

**Migration shows `up` in `mix ecto.migrations` but the column is missing**
The migration file was edited after it ran — normal during pre-deploy development, since
`schema_migrations` records the version, not the content. `mix ecto.reset`. Once anything is
deployed, editing an applied migration is off-limits; write a new one.

**An edited migration leaves the *test* database on the old schema, and CI never sees it**
This is the same cause as the row above, but the symptom is much quieter, so it gets its own
entry. `MIX_ENV=test` has its own `consensus_test<PARTITION>.db` file that persists between
runs, and the `test` alias's `ecto.create --quiet` / `ecto.migrate --quiet` are both no-ops
against a database whose `schema_migrations` already lists every version. Edit an applied
migration in place — the pre-deploy house style — and every local run keeps using the **old**
DDL.

A missing column announces itself (`** (Exqlite.Error) no such column: …`). A *renamed
constraint* does not. SQLite reports whatever the DDL called it, so with the old name still in
the file the changeset's `check_constraint(:id, name: :new_name)` no longer matches, the error
is never mapped onto the changeset, and the test that expected `{:error, changeset}` gets — this
is the `home_page` singleton constraint as it looked before D-027 deleted the table and its
changeset; no current schema in `lib/` declares a `check_constraint/3`, so treat the illustration
below as historical shape, not a live reproduction, and substitute your own table/constraint
names:

```
** (Ecto.ConstraintError) constraint error when attempting to insert struct:

    * "home_page_is_a_singleton" (check_constraint)

If you would like to stop this constraint violation from raising an
exception and instead add it as an error to your changeset, please
call `check_constraint/3` on your changeset with the constraint
`:name` as an option.

The changeset defined the following constraints:

    * "home_page_singleton" (check_constraint)
```

**The two lists disagreeing is the tell** — the database reported one name, the changeset
declared another. Nothing is wrong with the code; the local file is stale. CI passes on the
identical commit because it always starts from an empty database and migrates from scratch.
Rebuild yours:

```bash
export PATH="/opt/homebrew/bin:$PATH"
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.drop
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.create
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.migrate
```

(Verified end to end on 2026-08-08: the drop/create/migrate cycle replays both migrations,
including the literal `CREATE TABLE "home_page"` with its named CHECK.) Deleting the
`consensus_test<N>.db*` files by hand does the same thing. Do **not** reach for `mix ecto.reset`
here — that targets the shared dev database.

## Quick reference

| Task | Command |
|---|---|
| Migration status (dev) | `mix ecto.migrations` |
| Migration status (test) | `MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.migrations` |
| Run the suite on your own DB file | `MIX_TEST_PARTITION=7 mix test` |
| Create + migrate + seed | `mix ecto.setup` |
| Nuke and rebuild dev | `mix ecto.reset` |
| New migration | `mix ecto.gen.migration add_sessions` |
| Roll back one | `mix ecto.rollback` |
| Tables (on a copy) | `sqlite3 /tmp/inspect.db ".tables"` |
| Schema of a table | `sqlite3 /tmp/inspect.db ".schema users"` |
| Readable query output | `sqlite3 -header -box /tmp/inspect.db "select …"` |
| Health check | `sqlite3 /tmp/inspect.db "PRAGMA integrity_check; PRAGMA foreign_key_check;"` |
| Raw query from IEx | `Ecto.Adapters.SQL.query!(Consensus.Repo, "…", [])` |
| Consistent live backup | `VACUUM INTO '/data/backup.db'` |

**`mix precommit` is not CI.** CI (`.github/workflows/ci.yml`, job `test`, Elixir 1.20.3 / OTP
29.0.5, `MIX_ENV=test`) runs `mix deps.get --check-locked`, `mix deps.unlock --check-unused`,
`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. `precommit`
skips `--check-locked`, and its `format` / `deps.unlock --unused` steps **rewrite** files and
exit 0 where CI asserts and exits 1 — commit whatever they changed. It **does** honour
`MIX_TEST_PARTITION`, like every other mix invocation, so `MIX_TEST_PARTITION=7 mix precommit`
runs the whole gate against `consensus_test7.db`.

**The separate `docker` job builds the image *and boots it*, and the storage-layer assertions
live there.** It is the only place in the repo where a real release opens a real database file:

- `/data` is a **tmpfs owned by uid 65534, mode 0750** — how Fly presents an empty volume to a
  release running as `nobody`. That is what exercises `Consensus.BootCheck.run!/0`. Do not
  "fix" a failure there by running the container as root; a root-owned `/data` is exactly what
  the preflight exists to reject.
- `GET /health` must reach 200 `ok`, which it only can once the boot-time
  `{Ecto.Migrator, …}` child has applied every migration.
- The schema is then broken over `bin/consensus rpc` (`ALTER TABLE users RENAME TO users_gone`)
  and `/health` must answer **503** — the same "a check that cannot fail proves nothing"
  reasoning behind `health_controller_test.exs`.
- A **second step boots twice on one real Docker volume**: it renames the seeded admin, rolls
  the newest migration back down with `bin/consensus eval`, and requires the second boot to
  migrate a *populated* `users` table, log `== Migrated`, and leave the renamed admin intact.
  This is the closest thing the repo has to a production upgrade rehearsal — nothing else here
  ever migrates a database that already holds rows. It still does **not** cover a migration
  that has never run anywhere, so a bad `down`, or an `ALTER TABLE ... ADD COLUMN ... NOT NULL`
  that only fails against real rows, gets through.

Full transcription and a runnable local reproduction are in the `elixir` skill under
"Reproducing CI locally, completely". `docker build` on its own is not it.
