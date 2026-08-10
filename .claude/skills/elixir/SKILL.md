---
name: elixir
description: Elixir, OTP, Mix and Ecto working reference for the Consensus Phoenix app. Use when running mix tasks (compile, format, test, precommit, ecto.migrate) or picking a MIX_TEST_PARTITION, adding a child to the OTP supervision tree in Consensus.Application (including Consensus.LinkPreview.Cache), working on Consensus.Seeds or the bootstrap admin, writing or reviewing Ecto changesets and context functions in Consensus.Accounts or Consensus.Activities, injecting a test double for Consensus.LinkPreview's fetcher behaviour, deciding whether an ExUnit case may be async now that the suite runs `max_cases: 1`, writing tests with DataCase/ConnCase and the accounts/activities fixtures, decoding Elixir compiler warnings or --warnings-as-errors failures, debugging in IEx with dbg/recompile, or diagnosing Elixir/Ecto runtime errors such as Ecto.ConstraintError and constraint-name mismatches, Ecto.NoResultsError, "module is not available", mailer delivery errors, or SQLite migration failures.
---

# Elixir in the Consensus repo

Working reference for `/Users/aheld/Projects/consensus_app`. Everything below was run
or read against this repo. Elixir/Mix live in `/opt/homebrew/bin` — prepend
`export PATH="/opt/homebrew/bin:$PATH"` to shell invocations if `mix` is not found.

## Scope

**Use this for:** mix vocabulary, the supervision tree, Ecto/changeset conventions,
result-tuple style, ExUnit + sandbox mechanics, compiler-warning triage, IEx debugging.

**When NOT to use this:** HEEx/LiveView authoring, `<.input>`, streams, `phx-hook`,
forms — `AGENTS.md` at the repo root is the authority and is already in context.
Product scope → `docs/PRD.md`, `CLAUDE.md`. Settled technical choices →
`docs/decisions.md` (append there when you settle one). Deploy → `Dockerfile`,
`rel/overlays/bin/`, `config/runtime.exs`.

A pristine generator copy answers only "what does stock Phoenix 1.8.9 ship?" — never read it to
learn *this* app, never modify it. It is not committed (~230 MB with deps); regenerate one when you
need it — see the command in `.claude/skills/phoenix/SKILL.md`.

## Toolchain (verified 2026-08-08 — `elixir --version`, `mix.lock`)

| Thing | Version |
|---|---|
| Elixir / Erlang | 1.20.3 / OTP 29 (erts-17.0.5, stdlib 8.0.3) |
| Phoenix / LiveView | 1.8.9 / 1.2.8 |
| ecto / ecto_sql | 3.14.1 / 3.14.0 |
| ecto_sqlite3 / bcrypt_elixir | 0.24.1 / 3.3.2 |
| req | 0.7.2 — the HTTP client behind `Consensus.LinkPreview.Fetcher.Req`, the production `fetcher` |

`mix.exs` declares `elixir: "~> 1.17"` — that is the floor, not the toolchain. Write code
that compiles on 1.20.3.

## Mix vocabulary

The aliases are defined in `mix.exs` (`defp aliases/0`). Read them there rather than
memorising; as of now they expand to:

```
setup        -> deps.get, ecto.setup, assets.setup, assets.build
ecto.setup   -> ecto.create, ecto.migrate, run priv/repo/seeds.exs
ecto.reset   -> ecto.drop, ecto.setup
test         -> ecto.create --quiet, ecto.migrate --quiet, test
assets.setup -> tailwind.install --if-missing, esbuild.install --if-missing
assets.build -> compile, tailwind consensus, esbuild consensus
assets.deploy-> tailwind consensus --minify, esbuild consensus --minify, phx.digest
precommit    -> compile --warnings-as-errors, deps.unlock --unused, format, test
```

`mix help precommit` prints the live expansion plus `Location: mix.exs`.

- **`mix precommit` is the *local* gate, not CI.** `AGENTS.md` requires running it when you
  are done, and `def cli` in `mix.exs` sets `preferred_envs: [precommit: :test]` so it runs
  in `MIX_ENV=test`. It is necessary but not sufficient — see "`mix precommit` is not CI"
  near the bottom of this file for what CI actually runs — eight steps in job `test`, plus a
  `docker` job that **builds and boots** the release image and asserts against the running
  container.
- **Two of `precommit`'s four steps rewrite files instead of checking them.** `format` (not
  `format --check-formatted`) and `deps.unlock --unused` (not `--check-unused`) both edit
  your tree and exit 0. Run `mix format --check-formatted` and
  `mix deps.unlock --check-unused` first if you want to know what was already wrong before
  the alias silently fixed it.
- **`mix test` is an alias**, so `mix test path/to/file.exs` still creates and migrates
  the test DB first. A migration that raises therefore takes the *whole* suite down —
  you get a DDL stacktrace instead of any test output, no matter which file you named.
- **`MIX_TEST_PARTITION` picks the database file.** `config/test.exs:12` interpolates it:
  `consensus_test#{System.get_env("MIX_TEST_PARTITION")}.db`. Unset → `consensus_test.db`.
  If someone else may be running the suite against this checkout, take your own file:

  ```bash
  export MIX_TEST_PARTITION=7        # every mix command below now uses consensus_test7.db
  mix test
  mix precommit
  ```

  **Every mix invocation honours it, `precommit` included** — an alias runs its tasks in the
  same OS process and the config is read with `System.get_env/1`. Verified 2026-08-08 by
  deleting every `consensus_test*` file and running `MIX_TEST_PARTITION=6 mix precommit`: the
  gate went green and the only database files it created were `consensus_test6.db`,
  `consensus_test6.db-shm` and `consensus_test6.db-wal`. `consensus_test.db` was never created.
- **`precommit`'s `deps.unlock --unused` rewrites `mix.lock`; it does not police it.**
  Like `format`, it is a *fixer*, not a *checker*: it strips entries no longer mentioned in
  `deps/0` and exits **0**. So an unexplained `mix.lock` diff after `mix precommit` is
  `precommit`'s own work, and it must be committed — reverting it just makes CI fail.
  The checking flag is the one CI runs, `mix deps.unlock --check-unused`, which edits
  nothing and exits **1** on an unused entry. Confirm with `mix help deps.unlock`:
  *"`--unused` - unlocks only unused dependencies"* versus *"`--check-unused` - checks that
  the `mix.lock` file has no unused dependencies … useful in pre-commit hooks and CI
  scripts"*. Don't hand-edit `mix.lock` either way; let the tasks write it.

Useful `mix test` flags here: `--failed`, `--stale`, `--seed 0`, `--trace`,
`--max-failures 1`, `--repeat-until-failure N`, `--dry-run`, `--warnings-as-errors`
(the last cannot be retried with `--failed`).

`.formatter.exs` imports `:ecto`, `:ecto_sql`, `:phoenix`, loads
`Phoenix.LiveView.HTMLFormatter`, and covers `priv/*/migrations` — so `mix format`
also formats `~H` sigils and `.heex` files.

## Database: SQLite, and what that costs you

(Locking, WAL, backups and CLI details live in the `sqlite` skill. Here: only what
changes how you write Elixir.)

`Consensus.Repo` uses `Ecto.Adapters.SQLite3`. Paths: `consensus_dev.db` (dev),
`consensus_test<MIX_TEST_PARTITION>.db` (test), `DATABASE_PATH` env var in
`config/runtime.exs` (prod, a Fly volume at `/data`).

Consequences that bite:

1. **No `ALTER TABLE ADD CONSTRAINT`.** `Ecto.Migration.constraint/3` compiles to
   exactly that, so `create constraint(...)` type-checks fine and raises
   `** (ArgumentError) SQLite3 does not support ALTER TABLE ADD CONSTRAINT.` at run
   time (`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3/connection.ex:588`). A `CHECK`
   has to be inside the `CREATE TABLE`. `20260808040000_create_home_page.exs` solves
   that by writing the whole `CREATE TABLE` as literal SQL through `execute/2`
   (up/down); the adapter's `check: %{name: ..., expr: ...}` column option is the other
   route. See "The home page singleton" below — the constraint's *name* is load-bearing.
2. **Adding a `NOT NULL` + `UNIQUE` column to a populated table needs a table
   rewrite.** That is why `username` and `is_admin` were folded into the original
   `20260808033720_create_users_auth_tables` migration — see its header comment.
3. **`async: true` is fine, and this suite uses it.** See "ExUnit in this repo".
4. **Migrations run at application boot, not via a release command.** See the tree below.

Read-only inspection (prefer a copy of the dev file; the test file is yours):

```bash
sqlite3 consensus_test7.db ".schema activity_groups"
sqlite3 consensus_test7.db "select version from schema_migrations;"
```

## The OTP supervision tree

`lib/consensus/application.ex`, `strategy: :one_for_one`, name `Consensus.Supervisor`.
Order is load-bearing:

```
1. ConsensusWeb.Telemetry
2. Consensus.Repo
3. {Ecto.Migrator, repos: …, skip: skip_migrations?()}
4. {Consensus.Seeds, skip: skip_seeds?()}
5. {DNSCluster, query: …}
6. {Phoenix.PubSub, name: Consensus.PubSub}
7. ConsensusWeb.Endpoint
```

Children 3 and 4 are **synchronous, run-once, return `:ignore`** — they do their work
during supervisor init and leave nothing in the tree. `Consensus.Seeds` implements this
by hand (`child_spec/1` with `restart: :transient`, `start_link/1` calling `run!/0` then
returning `:ignore`); copy that shape if you ever need another boot-time step.

Three of these are public API, and deliberately so. **`Consensus.Application.children/0` returns
the list without starting it**, so `test/consensus/application_test.exs` can assert its shape;
`skip_migrations?/0` and `skip_seeds?/0` are public for the same reason. Deleting the
`Ecto.Migrator` child, deleting the `Consensus.Seeds` child, or moving either after
`ConsensusWeb.Endpoint` is a production outage no request-level test can observe — hence the
structural test.

`start/2` calls a private `preflight!/0` **before** the list is built, which is
`if skip_migrations?(), do: :ok, else: Consensus.BootCheck.run!()` — releases only, never under
`mix`. **`Consensus.BootCheck` is its own module** (`lib/consensus/boot_check.ex`), not a private
function on `Application`, because `Consensus.Release` calls it too: **all three** of its entry
points — `migrate/0`, `seed/0` **and** `rollback/2` — preflight, via a private `preflight!/1`
that hands the repo's *own* configured `:database` to `BootCheck.run!/1` rather than calling the
zero-arity form (so a repo passed to `rollback/2` by name is checked against the file it will
actually open). They run in a fresh node via `bin/consensus eval` and are exactly what an
operator reaches for when something is already wrong. `BootCheck`'s surface is `run!/0` (reads
the repo config; `:ok` when there is none), `run!/1` (an explicit path) and
`on_root_filesystem?/1`. It checks three things — the directory exists and is writable;
**every member of the WAL set that exists** (`DATABASE_PATH` plus its `-wal` and `-shm`
sidecars) opens for `:append`, with the message naming the path that actually refused; and the
directory is on a different device from `/` — raising a message that quotes `DATABASE_PATH`, the
directory's `uid:gid` and octal mode, and the fix. Note the last check's asymmetry: on Fly
(`FLY_APP_NAME` set) a database outside the mount **raises**, everywhere else it only
`Logger.warning`s, so a bare `docker run` with no `-v` still starts. It exists because an
unwritable volume otherwise surfaces as eleven `database_open_failed` lines and a
`DBConnection.ConnectionError` about connection pools (D-016). Deployment detail lives in the
`fly-io` skill; what matters here is that **anything raising ahead of `Supervisor.start_link/2`
kills the node before anything is supervised** — keep that budget for one-line preconditions.

`skip_migrations?/0` is true unless `RELEASE_NAME` is set, i.e. migrations run in
releases only. `skip_seeds?/0` defaults to the same and is overridden by
`config :consensus, :seed_on_boot, true|false`. `config/test.exs:21` sets it to `false`
explicitly, so the suite is never seeded behind ExUnit's back even if someone runs the
tests with `RELEASE_NAME` in the environment. Several `Accounts.count_users/0` and
`list_users/0` assertions depend on that starting from zero.

`Consensus.Seeds.run!/0` is idempotent and returns `{:ok, %{admin: admin_or_nil}}` — the
`:home_page` key that used to sit alongside `:admin` is gone, along with the home page
itself (D-027). It creates a bootstrap admin only when
**`Accounts.count_admins() > 0` is false** — the gate is "does this database
have any administrator?", deliberately *not* "does the user `aheld` exist?", so renaming
or re-emailing the seeded account cannot make the next boot look like a first boot and
resurrect `aheld` / `adminpass`. `test/consensus/seeds_test.exs` pins both of those
regressions. On a misconfiguration it raises only when `Accounts.count_users() == 0`
(genuine first boot, fail the deploy); otherwise it logs and returns `nil` so an operator
can still get in and repair it.

`Seeds` also exposes `admins_with_default_password/0` — every admin whose password still
verifies against the built-in `adminpass` — and `default_password_in_use?/0` on top of it.
It costs one bcrypt verification per admin, so call it from an admin page (which
`ConsensusWeb.AdminLive.Users` does, to render its banner) and never per request. It checks
the *password*, not the username: renaming the bootstrap account does not make it safe.

### Rules for adding a child

- **Placement:** the Endpoint stays last; anything it depends on goes before it.
  Anything touching the DB goes after `Consensus.Repo`, and after `Ecto.Migrator` +
  `Consensus.Seeds` if it assumes a current schema or a seeded row.
- **Name it.** `DynamicSupervisor`, `Registry`, `Task.Supervisor` and
  `PartitionSupervisor` all need an explicit name in the child spec, e.g.
  `{DynamicSupervisor, name: Consensus.SessionSupervisor}`, then
  `DynamicSupervisor.start_child(Consensus.SessionSupervisor, spec)`.
- **Never crash the boot for something optional.** A child that raises in `init` takes
  the node down before the Endpoint binds a port. If it can fail, make it
  supervised-and-restartable, not synchronous.
- **Don't start processes in tests via the tree** — `start_supervised!/1` inside the test.
- Consensus sessions are ephemeral and deadline-driven (`CLAUDE.md` invariant 3). A
  per-session timer/GenServer belongs under a named `DynamicSupervisor` added here,
  and the decision belongs in `docs/decisions.md`.

## Ecto & context conventions

The generated `Consensus.Accounts` context is the model. Follow it.

**Changesets live on the schema, orchestration lives in the context.**
`Consensus.Accounts.User` exposes narrow, purpose-named changesets —
`registration_changeset/3`, `email_changeset/3`, `password_changeset/3`,
`username_changeset/3`, `admin_changeset/2`, `confirm_changeset/1` and
`confirm_and_clear_password_changeset/1`. The context calls them and touches `Repo`.

**Narrow the cast.** `admin_changeset/2` casts `[:is_admin]` and nothing else, precisely
so an admin-only endpoint cannot smuggle an email or password change through.
`Consensus.Activities.Group.status_changeset/2` is the same idea for a lifecycle field: it
casts only `[:status, :completed_at, :cancelled_at]`, kept apart from the organizer-facing
`changeset/2` so a public edit form can never smuggle a status transition through `attrs`.
Fields set programmatically — `organizer_id` on a `%Group{}`, `group_id`/`added_by_id`/
`position` on an `%Activity{}` — are **never** in `cast/3`; `Consensus.Activities.create_group/2`
and `add_activity/3` set them directly on the struct (`%Group{organizer_id: user_id}`,
`%Activity{group_id: group.id, added_by_id: user_id}`) before handing it to the schema's
changeset.

**Options keyword instead of a second changeset**, via `Keyword.get(opts, :flag, default)`
inside a private validator. `registration_changeset/3` threads `opts` into
`validate_email`, `validate_username` and `validate_password`. `:validate_unique false`
and `:hash_password false` are for live form validation (skip the query / the bcrypt
round); `:validate_length false` exists for exactly one caller, `Consensus.Seeds`, which
needs the documented `adminpass` default past `@min_password_length 12`. Read that call
carefully before copying it — the private `Seeds.create_bootstrap_admin/0` passes the option **only** when
`password == @default_password`. An operator who sets `ADMIN_PASSWORD` is held to the full
12-character rule, because waiving it for them would silently accept a one-character
production admin password.

**Read paths come in bang and non-bang pairs, and the non-bang one is for client input.**
`Accounts` currently exposes `get_user!/1` (raises `Ecto.NoResultsError`), `get_user/1`,
`get_user_by_email/1`, `get_user_by_username/1`, `get_user_by_login/1` (routes on
`String.contains?(login, "@")`), the `*_and_password` variants, `list_users/0`,
`list_admins/0`, `count_admins/0` and `count_users/0`. Use `get_user/1` for an id that
arrived from a LiveView event — an admin clicking a stale row should get "no such user", not
a crashed socket. Note its two clauses: the first matches
`is_integer(id) and id > 0 and id <= @max_row_id` and calls `Repo.get/2`; the second catches
every other integer and returns `nil`. The bound is not decoration — `Repo.get/2` does **not**
politely return `nil` for a 26-digit id, exqlite raises (D-016). `Consensus.Activities` follows
the same shape for a different reason: `get_group!/2` is scoped to the organizer and raises
`Ecto.NoResultsError` both when the id is missing and when it belongs to someone else — the two
are indistinguishable from outside, which is the point — while `get_group_by_slug/1` is the
**unscoped** non-bang read the future `/join/<slug>` page will use, returning `nil` for a bad
slug rather than raising on a guest's typo.

**Writes that an admin performs take the actor's scope and return more than the row.**
`set_admin/3` **and** `delete_user/2` both return `{:ok, {user, tokens_to_disconnect}}` — the
same shape, for the same reason: the caller has to hand those tokens to
`ConsensusWeb.UserAuth.disconnect_sessions/1` or a socket that is already mounted keeps a
scope it should no longer have. (`delete_user/2` collects them *before* the delete, since the
`ON DELETE CASCADE` takes them with it.) Inside one `Repo.transact/1` both re-read the actor
from the database **and** require the actor to still be in **sudo mode** —
`ensure_actor_in_sudo_mode/1`, `{:error, :sudo_required}` otherwise. Granting the admin role
or destroying an account is account-takeover-grade, so it is held to the same freshness bar as
changing your own credentials. Both also emit a private `audit/4` `Logger` line —
`[audit] <action> actor_id=… target_id=…` at `:info` on success,
`[audit] <action> REFUSED <reason> …` at `:warning` on refusal — and `audit/4` returns its
input unchanged, so it can never alter what the caller sees. Username
changes are plain: `change_user_username/3` builds the changeset (opts thread through to
`User.username_changeset/3`) and `update_user_username/2` writes it, with **no** confirmation
round-trip — a username is an in-app identifier, not proof of controlling an inbox.

**Access changeset fields with the API, never with brackets.** `changeset[:field]`
raises — structs do not implement `Access`. Use `Ecto.Changeset.get_field/2`,
`get_change/2`, `fetch_field/2`.

**Transactions use `Repo.transact/1`** (Ecto 3.14; verified present in
`deps/ecto/lib/ecto/repo.ex`). The function returns `{:ok, value}` or `{:error, reason}`
and the tuple decides commit vs rollback — no `Repo.rollback/1` plumbing:

```elixir
Repo.transact(fn ->
  case Repo.get(User, user.id) do
    nil -> {:error, :not_found}
    user -> user |> User.admin_changeset(%{is_admin: true}) |> Repo.update()
  end
end)
```

Re-read rows inside the transaction when a check and a write must see the same snapshot.
`Accounts.set_admin/3` does exactly that: inside `Repo.transact/1` it re-fetches the actor
(to confirm they are still an admin), checks the actor's sudo freshness, re-fetches the
target, then runs the last-admin guard — because the caller's structs may be stale by the time
the write lands. `delete_user/2` uses the identical `with` chain, substituting
`refuse_self_deletion/2` and `refuse_admin_deletion/1` for the last-admin guard.

**Authorization is a function clause, not an `if`.** `Consensus.Activities` is the model now
that `Consensus.Content` is deleted (D-027): its function heads bind the scope's `user_id` and
the resource's owner id to the *same variable name* —
`update_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group, attrs)`
— so a call on someone else's group fails to match any clause and raises `FunctionClauseError`
rather than taking a runtime branch. `create_group/2`, `publish_group/2`, `cancel_group/2`,
`complete_group/2`, `add_activity/3` and `reorder_activities/3` all follow this shape. Contexts
take `current_scope` as the first argument (see `AGENTS.md`).

**The one deliberate exception is a DB re-read, not a pattern match, and it is documented as
such in the module.** `update_activity/3` and `delete_activity/2` take an `%Activity{}`, which
carries only `group_id` — not the organizer id — so there is no owner field to bind against the
scope's `user_id` in the function head. Both instead call a private `authorize_activity/2` that
re-fetches the `%Group{}` by `group_id` and matches its `organizer_id`, returning
`{:error, :unauthorized}` for someone else's group or `{:error, :not_found}` for a group that no
longer exists — the same "don't trust the struct in hand, re-read from storage" idiom
`Accounts.set_admin/3` uses for its actor (D-016).

**Queries:** `import Ecto.Query, warn: false` at the top of the context; keyword syntax
inline (`Repo.all(from(u in User, order_by: [asc: u.inserted_at, asc: u.id]))`).
Preload anything a template will touch.

### `Consensus.LinkPreview` — an injected fetcher behaviour and an ETS-backed OTP child

Not an Ecto context at all — `lib/consensus/link_preview.ex` fetches OpenGraph/HTML metadata
for a pasted URL, and it is worth knowing as a *non*-database pattern alongside `Accounts` and
`Activities`.

- **`Consensus.LinkPreview.fetch/1`** never touches the network directly. It calls
  `Application.get_env(:consensus, __MODULE__, [])[:fetcher] || Fetcher.Req` and invokes that
  module's `get/2` — a `@behaviour Consensus.LinkPreview.Fetcher`. `config/config.exs` (or
  `config/test.exs`) supplies the module; in test it is `Consensus.LinkPreviewStub`
  (`test/support/link_preview_stub.ex`), which has no Mox dependency and instead stores a
  per-process response function with `Process.put/2`, looked up by walking `self()` and then
  `Process.get(:"$callers", [])` — the mechanism `Task` uses to make a spawning test process
  discoverable from the `Task` it starts. That is what makes a stub installed by an ExUnit test
  visible from inside a LiveView's `start_async` Task; see the `phoenix` skill for why that
  matters and the trap it avoids.
- **The cache is a real supervised child, not a per-call detail.** `Consensus.LinkPreview.Cache`
  is a `GenServer` whose `init/1` does nothing but `:ets.new(@table, [:set, :public,
  :named_table, read_concurrency: true])` — the GenServer exists only to give the table a
  lifetime tied to the supervision tree; `get/1`, `put/2`, `flush/0` and `size/0` all touch the
  ETS table directly, never `GenServer.call/2`. It sits in `Consensus.Application.children/0`
  after `Consensus.Repo` and before `ConsensusWeb.Endpoint` (no database dependency of its own,
  so its exact position within that range is not asserted, only the range — see
  `test/consensus/application_test.exs`, `"starts the link preview cache after the repo and
  before the endpoint"`). Both `{:ok, _}` and `{:error, _}` results are cached, on different
  TTLs (`cache_ttl_ms`, default 6h; `cache_error_ttl_ms`, default 5m) — a broken link pasted
  five times costs one outbound request, not five.
- **The SSRF guard resolves the host, not just parses it**, and re-checks on every redirect hop
  — `check_host/1` rejects loopback/private/link-local addresses and a short blocklist
  (`localhost`, the cloud metadata hostname) before the first request and again after following
  a `location` header, because a public host that 302s to `10.0.0.1` would otherwise defeat a
  check done only once. `perform_fetch/2` never raises into its caller: `safe_perform_fetch/1`
  wraps it in both `rescue` and `catch kind, reason` — the same "an exit is not caught by
  `rescue`" lesson `UserNotifier` teaches, applied to an HTTP fetch instead of a mailer.

### `Consensus.Deadlines` — pure functions, no database, no `Repo`

`lib/consensus/deadlines.ex` computes the three deadline chips on `01 setup`
(`Consensus.Deadlines.options/2`) entirely from a UTC `DateTime` and an integer offset in
minutes — no schema, no changeset, no `Repo` call anywhere in the module. It is the module to
reach for as an example of "this doesn't need to be a context" when a future feature is pure
computation dressed up as domain logic. Every function is unit-testable with nothing but plain
data, which is exactly what `test/consensus/deadlines_test.exs` does — no `DataCase`, no
sandbox, `use ExUnit.Case, async: true`, and it is safe async because nothing it does touches
shared state. See the `phoenix` skill for why the browser (not the server) is the source of the
UTC offset, and CLAUDE.md's product invariant about there being no `tzdata` dependency.

## Pattern matching, `with`, and result tuples

- Public context functions return `{:ok, value}` | `{:error, reason}`; the bang variants
  (`get_group!/2`, `get_user!/1`) raise. Keep both flavours honest. `Seeds.run!/0`
  is the odd one out and the naming is deliberate: it returns `{:ok, map}` on the happy
  path and raises only on an unusable first-boot configuration.
- Error reasons are atoms the caller can match, and the set has grown well past
  `Consensus.Accounts` since `Consensus.Activities` and `Consensus.LinkPreview` landed.
  Reproduce it rather than trust this list — `grep -rhon '{:error, :[a-z_]*}' lib/ | sed
  's/^[0-9]*://' | sort -u` — because it is the literal command this paragraph was written
  from and it is stale the moment a new context adds a reason. As of this writing:
  `:already_finished`, `:blocked_host`, `:fetch_failed`, `:group_not_open`, `:invalid_ids`,
  `:invalid_url`, `:is_admin`, `:last_admin`, `:no_activities`, `:no_deadline`, `:not_draft`,
  `:not_found`, `:not_html`, `:self`, `:sudo_required`, `:too_many_redirects`,
  `:transaction_aborted`, `:unauthorized` — plus two tagged shapes the grep above cannot
  find because they are not bare atoms: `{:database_busy, message}`, which **both**
  `Accounts.set_admin/3` and `delete_user/2` rescue `Exqlite.Error` into
  (`accounts.ex:214` and `:305`), and `{:http, status}`, one of `Consensus.LinkPreview.fetch/1`'s
  own reasons for a non-2xx response. Reuse an existing reason before inventing a synonym — a
  `:not_found` in `Activities` means the same thing it does in `Accounts`.
  (`:not_confirmed` is **gone** — D-015 removed the refusal it
  reported; see below. `grep -rn not_confirmed lib/ test/` is empty.) Don't return bare
  strings.
- Use `with` when every step is a happy-path `{:ok, _}` and the `else` is genuinely a
  single fallback. `Accounts.update_user_email/2` is the canonical example, and
  `set_admin/3` / `delete_user/2` use the same shape *inside* `Repo.transact/1`. When each
  failure needs its own reason, use `case` — as `login_user_by_magic_link/1` does.
- `with {:ok, x} <- expr do … end` **without** an `else` passes the non-matching value
  straight through. `Consensus.Activities.update_activity/3` relies on this: its only clause is
  `with {:ok, group} <- authorize_activity(scope, activity) do ... end`, so an `{:error,
  :unauthorized}` or `{:error, :not_found}` from the private authorization check forwards to the
  caller untouched, with no `else` needed.
- Guard-clause naming: predicates end in `?` (`sudo_mode?`, `valid_password?`,
  `default_password_in_use?`); `is_` prefixes are reserved for real guards.
- Repeat a variable in a head to express "same value". `Accounts` short-circuits a no-op
  admin update with `defp apply_admin_change(%User{is_admin: is_admin} = user, is_admin)`
  — `is_admin` appearing twice means the clause only matches when the stored role already
  equals the requested one. Use a pin (`^is_admin`) when the value is bound outside the head.

## ExUnit in this repo

The whole suite, so you know where a new test belongs:

```
test/consensus/            accounts_test.exs  activities_test.exs  application_test.exs
                           boot_check_test.exs  deadlines_test.exs  deploy_config_test.exs
                           link_preview_test.exs  release_test.exs  seeds_test.exs
test/consensus/accounts/   user_notifier_test.exs
test/consensus_web/        journey_test.exs  router_test.exs  user_auth_test.exs
test/consensus_web/controllers/  error_html_test.exs  error_json_test.exs
                                 health_controller_test.exs
                                 user_session_controller_test.exs
test/consensus_web/live/   home_live_test.exs
test/consensus_web/live/admin_live/     users_test.exs
test/consensus_web/live/group_live/     new_test.exs  options_test.exs  review_test.exs
                                        share_test.exs
test/consensus_web/live/user_live/      confirmation_test.exs  login_test.exs
                                        registration_test.exs  settings_test.exs
test/support/               conn_case.ex  data_case.ex  link_preview_stub.ex
                            fixtures/accounts_fixtures.ex  fixtures/activities_fixtures.ex
```

`Consensus.Content`, `Consensus.Content.HomePage`, `ConsensusWeb.AdminLive.HomePage` and
`test/consensus/content_test.exs` / `test/consensus_web/live/admin_live/home_page_test.exs` are
all **deleted** (D-027, the admin-editable home page). If you see any of those five names, the
document naming them is stale.

`find test -name '*_test.exs' | sort` is the current answer; several agents are adding files
to this tree, so re-run it rather than trusting the block above.

Three of these cover the boot path, which no request can reach — so nothing else in the suite
notices when it breaks:

- **`application_test.exs`** asserts the *shape* of the supervision tree, because there is no
  `[deploy] release_command` (D-009): the tree is the only thing that migrates a release and
  the `Consensus.Seeds` child is the only thing that gives a fresh deploy an administrator
  (D-010). A `RELEASE_NAME` boot against a fresh volume can answer `no such table: users` with
  the entire rest of the suite green. Same spirit as `router_test.exs`.
- **`boot_check_test.exs`** exercises `Consensus.BootCheck.run!/1` against real directories
  under a per-test `@tmp_dir` — both the unwritable-volume raise and the not-a-mount warning,
  each of which is otherwise silent until production.
- **`release_test.exs`** covers `Consensus.Release.migrate/0` and `rollback/2` against a
  throwaway repo pointed at a tmp-dir database, so the suite's own file is never migrated or
  rolled back by them. It is mix-free code no other test loads.
- **`deploy_config_test.exs`** is not about the boot path but belongs in the same family: it
  reads `fly.toml` as text and asserts the file agrees with *itself* — `PHX_HOST == app <>
  ".fly.dev"`, `PORT == internal_port`, `DATABASE_PATH` inside `[[mounts]] destination`. Those
  are two-place edits nothing else checks, and a wrong `PHX_HOST` 403s every LiveView socket
  in production while `GET /` and `/health` both keep answering 200. `use ExUnit.Case,
  async: true`; no database.

Two more are worth knowing about before you touch authorization:

- **`test/consensus_web/router_test.exs`** asserts that every `/admin` route carries *both*
  guards — the `:require_admin_user` plug and the `{UserAuth, :require_admin}` `on_mount`.
  `ConsensusWeb.Router.__routes__/0` (generated by `Phoenix.Router`) does not expose `pipe_through`, so the plug half is asserted
  against the router *source*; the file says so in a comment. Crude, but it is the only thing
  that notices someone deleting the plug, because the on_mount hook would keep every
  behavioural test green.
- **`test/consensus_web/user_auth_test.exs`** covers `disconnect_sessions/1`,
  `require_admin_user/2` and `on_mount :require_admin` in their own `describe` blocks,
  including a demoted admin's live session being cut off.

Two case templates, both in `test/support/` (compiled only in `:test` via
`elixirc_paths(:test)`):

- **`Consensus.DataCase`** — context/schema tests. Imports `Ecto`, `Ecto.Changeset`,
  `Ecto.Query`, aliases `Repo`, provides `errors_on/1`.
- **`ConsensusWeb.ConnCase`** — controller and LiveView tests. Brings `Plug.Conn`,
  `Phoenix.ConnTest`, `use ConsensusWeb, :verified_routes` (so `~p"/users/log-in"`
  works), `@endpoint`, plus `register_and_log_in_user/1` and `log_in_user/3`.

Both call `Consensus.DataCase.setup_sandbox/1`, which does
`Ecto.Adapters.SQL.Sandbox.start_owner!(Consensus.Repo, shared: not tags[:async])` and
stops the owner `on_exit`. `test/test_helper.exs` puts the repo in `:manual` mode.

### `async: true` and SQLite — the actual rule (D-033)

**The suite runs its cases one at a time.** `test/test_helper.exs` calls
`ExUnit.start(max_cases: 1)`, so nothing in this repo runs concurrently regardless of an
individual case's `async:` tag. That is a change from how this skill used to describe things,
and the old reasoning ("the sandbox plus a 5s `busy_timeout` make concurrent writers safe") was
incomplete in a way that only showed up once the suite grew: SQLite permits exactly one write
transaction across the whole database file, the sandbox holds each test's transaction open for
the *entire test*, and **`busy_timeout` is never consulted in that collision** — a connection
already inside a transaction that tries to upgrade to a write cannot be made to wait (blocking
could deadlock it against itself), so SQLite returns `SQLITE_BUSY` immediately and the busy
handler never runs. Measured at 438 tests: ~50 failures a run at the old default
`max_cases: 20`, still ~46 at `--max-cases 2`, zero at `--max-cases 1`. Full mechanism,
including why `journal_mode: :wal` and `default_transaction_mode: :immediate` were tried in
`config/test.exs` first and did not help, lives in the `sqlite` skill — this section only
covers what changes about writing a *test*.

**`async: true` is still worth setting, and still means what it always meant under the
sandbox** — `shared: not tags[:async]` gives an `async: true` case its own checked-out
connection and its own transaction, rolled back at exit, instead of joining the shared owner, so
tests still cannot see each other's rows. It just no longer buys concurrent wall-clock time,
because `max_cases: 1` removes that regardless of the tag.

Verified 2026-08-09: `MIX_TEST_PARTITION=p11 mix precommit` → **964 tests, 0 failures**,
"Finished in 6.0 seconds (1.9s async, 4.1s sync)". Re-run for a current count rather than
quoting that number — the count grows as the app is written.

**Always pass `MIX_TEST_PARTITION` when anything else might be running the suite.** Two
concurrent `mix test` runs against the same unpartitioned `consensus_test.db` produce real
failures, not flakiness: row counts and orderings come back off by exactly the other run's
rows. Every "pre-existing failure" seen during this feature's build turned out to be either
that or a file caught mid-edit.

`test/consensus/activities_test.exs` is `use Consensus.DataCase, async: true` and does plenty of
database work — inserts, updates, deletes, a `Repo.transact/1` reorder, a PubSub broadcast
assertion. It passes, because the suite no longer runs concurrently. Copy it for a new context
test; `test/consensus/content_test.exs`, which this skill used to point at, is deleted along with
`Consensus.Content` (D-027).

**What forces `async: false` is global mutable state or file-level DDL — not ordinary database
work, and not concurrency any more.** Six files are pinned, and every one of them says why in a
comment:

| File | Why |
|---|---|
| `test/consensus/seeds_test.exs` | `System.put_env`/`delete_env` on `ADMIN_USERNAME`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` — the OS environment is per-node, so a parallel test would read another test's admin config |
| `test/consensus/accounts/user_notifier_test.exs` | `Application.put_env(:consensus, Consensus.Mailer, ...)` to swap in a deliberately exiting or failing Swoosh adapter, restored in `on_exit` |
| `test/consensus/application_test.exs` | mutates `RELEASE_NAME` and application env; never touches the repo (`use ExUnit.Case`) |
| `test/consensus/boot_check_test.exs` | real directories, permissions and `Logger` capture (`use ExUnit.Case`) |
| `test/consensus/release_test.exs` | starts a throwaway repo of its own against a tmp-dir database file |
| `test/consensus/link_preview_test.exs` | `Consensus.LinkPreview.Cache`'s ETS table is one named, process-global table (a real supervised child, not started per test), and some cases override `Application.put_env(:consensus, Consensus.LinkPreview, cache_error_ttl_ms: ...)` to make an expiry observable in milliseconds |
| `test/consensus_web/controllers/health_controller_test.exs` | **the interesting one, and the one that still matters after D-033** — proving `/health` can fail means running DDL (`ALTER TABLE … RENAME`), and SQLite takes an exclusive lock on the *whole file* for that, which collides with a *shared* (non-async) connection holding a read transaction even when nothing runs concurrently in wall-clock time. The DDL still rolls back with the sandbox transaction. |

That last row is the rule to generalise: **a test that issues DDL must be `async: false`**, even
though ordinary inserts and updates are perfectly safe async.

Explicit `async: true` today: `test/consensus/activities_test.exs`,
`test/consensus/deadlines_test.exs` (pure, `use ExUnit.Case` — no database),
`test/consensus/deploy_config_test.exs` (`use ExUnit.Case` — reads `fly.toml` as text, no
database), `test/consensus_web/router_test.exs` (`use ExUnit.Case` — no database),
`test/consensus_web/journey_test.exs`, `test/consensus_web/live/group_live/new_test.exs`,
`test/consensus_web/live/group_live/options_test.exs`,
`test/consensus_web/live/home_live_test.exs`, and the two controller tests
`error_html_test.exs` / `error_json_test.exs`. Everything else — `accounts_test.exs`,
`user_auth_test.exs`, `user_session_controller_test.exs`, `admin_live/users_test.exs`,
`group_live/review_test.exs`, `group_live/share_test.exs`, and every `user_live/*` test — carries
**no** `async:` flag at all, which means `false` by default: inherited from the generator, not a
considered decision. Adding `async: true` to one of those is still a legitimate change — it
buys isolation hygiene even without concurrency — run it a few times with
`--repeat-until-failure 20` to be sure. Re-derive this list with
`grep -rn "use Consensus.DataCase\|use ConsensusWeb.ConnCase\|use ExUnit.Case" test` rather than
trusting it verbatim.

Fixtures: `test/support/fixtures/accounts_fixtures.ex` (`Consensus.AccountsFixtures`) —
`unique_user_email/0`, `unique_username/0`, `valid_user_password/0`,
`valid_user_attributes/1`, `unconfirmed_user_fixture/1`, `user_fixture/1`,
`admin_fixture/1`, `user_scope_fixture/0,1`, `admin_scope_fixture/1`, **`stale_scope/1`**,
`set_password/1`, `extract_user_token/1`, `override_token_authenticated_at/2`,
`generate_user_magic_link_token/1`, `offset_user_token/3`.

`test/support/fixtures/activities_fixtures.ex` (`Consensus.ActivitiesFixtures`) is the newer,
smaller sibling — `unique_group_title/0`, `unique_activity_name/0`, `future_deadline/0`,
`past_deadline/0`, `group_fixture/2` (takes a `%Scope{}` plus attrs), `activity_fixture/2`
(takes a `%Group{}` plus attrs). Both `*_deadline/0` helpers are `DateTime.add(..., :second)`
one day either side of now — use `past_deadline/0` for a group that should have already
auto-completed under `maybe_complete_group/1`, not a hand-built timestamp.

`test/support/link_preview_stub.ex` (`Consensus.LinkPreviewStub`) is not a fixture in this
sense — it is the injected `Consensus.LinkPreview.Fetcher` implementation for `:test`, installed
per-process with `stub/1` (or `stub_html/2` for the common "answer this HTML at 200" case). See
the `Consensus.LinkPreview` note above for why it walks `$callers` rather than just the calling
process.

`stale_scope/1` is the one to reach for when testing the sudo-mode refusals: it takes a
`%Scope{}` or a `%User{}` and returns a scope whose `authenticated_at` is outside the
20-minute window, which is what makes `Accounts.set_admin/3` and `delete_user/2` answer
`{:error, :sudo_required}`.

`valid_user_attributes/1` supplies `:email`, `:username` **and** `:password` — this
app's `registration_changeset/3` requires all three, unlike the generator's. `user_fixture/1`
registers, confirms through `login_user_by_magic_link(token)` — which **always** clears the
password on an unconfirmed account — and then calls `set_password/1` to put it back, so a
confirmed fixture authenticates with `valid_user_password/0` the way most callers assume. That
trailing `set_password/1` is load-bearing; drop it and every password-login assertion in the
suite fails against a `%User{hashed_password: nil}`. `admin_fixture/1` builds on
`user_fixture/1` and writes `is_admin` through `User.admin_changeset/2` and `Repo.update/1`
directly, not through `Accounts.set_admin/3` — that function demands an admin actor, which
the *first* admin cannot have. The fixture carries a comment saying so.

### `login_user_by_magic_link/1` — arity **1**, refuses nothing, always discards (D-015)

Two things have changed here and both bite. The function used to return
`{:error, :not_confirmed}` when it found an unconfirmed account that already held a password;
it does not any more, and no code path in `lib/` returns that atom (`grep -rn not_confirmed
lib/ test/` is empty). And it used to take the currently-signed-in user as a second argument;
**it does not any more** — `lib/consensus/accounts.ex:566` reads `def
login_user_by_magic_link(token) do`. Calling it with two arguments raises
`UndefinedFunctionError`. Three cases now, from its `case Repo.one(query)`:

| Found | Result |
|---|---|
| `confirmed_at: nil`, password set | `User.confirm_and_clear_password_changeset/1` — confirmed, logged in, password **discarded**, with **no exception** for a caller already signed in as that user |
| `confirmed_at: nil`, no password | `User.confirm_changeset/1`, all tokens deleted |
| already confirmed | the magic-link token is deleted and the user returned |

All three return `{:ok, {user, expired_tokens}}`; a miss is `{:error, :not_found}`. The
rationale is in the function's own `@doc`: the only way a session can exist for an
*unconfirmed* account in this app is registration itself, so such a session was minted by the
very password under suspicion — honouring it would narrow credential pre-stuffing to session
fixation rather than close it. Whoever reads the inbox owns the account.

**Callers must expect a `%User{hashed_password: nil}` back and say so to the person** —
`UserSessionController`'s private `magic_link_info/2` matches on `%{hashed_password: nil}` and
flashes *"the password that was set on this account has been removed"* instead of the usual
"You're in — this address is confirmed.", and `ConsensusWeb.UserLive.Confirmation` warns before the button is pressed
(its assign is `@clears_password?`, computed as `is_nil(user.confirmed_at) and not
is_nil(user.hashed_password)` — no scope input). Nothing in this repo should say a magic link
is refused, that a user has to "log in with their password first", or that being signed in
preserves the password.

Assertion idioms already in use:

```elixir
assert {:error, changeset} = Accounts.register_user(%{})
assert %{password: ["can't be blank"]} = errors_on(changeset)

%{id: id} = user = user_fixture()
assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
```

`config/test.exs`: `log_rounds: 1` for bcrypt, `busy_timeout: 5_000`, `pool_size: 5`,
`seed_on_boot: false`, `Swoosh.Adapters.Test`, logger `:warning`, LiveView
`enable_expensive_runtime_checks: true`, `sort_verified_routes_query_params: true`.
The logger level matters when asserting on log output: `user_notifier_test.exs` has to
pass `level: :warning` to `Swoosh.Adapters.Logger` (production uses `:info`) for
`capture_log` to see anything.

Per `AGENTS.md`: `start_supervised!/1` for processes, never `Process.sleep/1`; use
`Process.monitor/1` + `assert_receive {:DOWN, …}` or `_ = :sys.get_state(pid)`.

## Elixir 1.20 / OTP 29 specifics that matter here

Grounded in `/opt/homebrew/Cellar/elixir/1.20.3/CHANGELOG.md`:

- **The type system now infers across clauses, guards, and function bodies**, and warns
  on *redundant clauses* and *unused requires*. Expect new warnings on code that was
  clean on 1.17. Under `--warnings-as-errors` these are build failures, not noise — a
  redundant-clause warning usually means a real dead branch.
- `require SomeModule` no longer expands to the module at compile time (it still returns
  it at runtime), so `require(Mod).fun()` breaks. Raw CR line endings are now rejected
  in strings and comments.
- `dbg/1` prints intermediate results for pipes — `|> dbg()` shows each stage.
  `mix source MODULE` / `IEx.Helpers.source/1` print a module's source location, faster
  than grepping `deps/`. `mix test --dry-run` lists what would run.
- New stdlib bits: `List.first!/1`, `List.last!/1`, `Integer.ceil_div/2`,
  `Integer.popcount/1`, `IO.iodata_empty?/1`, `Process.get_label/1`.
- **`DateTime.utc_now(:second)`** is the house style — the schemas use
  `timestamps(type: :utc_datetime)`, and `:utc_datetime` **rejects microseconds**.
  `User.confirm_changeset/1`, `Consensus.Seeds` (the `confirmed_at` it hands to
  `Accounts.create_user/2`) and `AccountsFixtures.offset_user_token/3` all truncate
  this way.
- Never `String.to_atom/1` on user input (unbounded atom table). Use
  `String.to_existing_atom/1`, as `DataCase.errors_on/1` does.

## Reading compiler warnings

Elixir 1.20 prints a source excerpt and a `└─ file:line:col: Mod.fun/arity` footer:

```
warning: variable "x" is unused (if the variable is not meant to be used, prefix it with an underscore)
│
2 │   def a(x), do: :ok
│         ~
│
└─ lib/foo.ex:2:9: Foo.a/1
```

Read the footer first — it names the exact function, which the excerpt does not.

The three you will actually hit:

| Warning | Means | Fix |
|---|---|---|
| `variable "x" is unused` | dead binding | prefix `_x`, or delete |
| `Mod.fun/1 is undefined or private. Did you mean: …` | typo or wrong arity | fix the call; the suggestion list is usually right |
| `Mod.__live__/0 is undefined (module … is not available or is yet to be defined)` | a `live` route in `router.ex` points at a LiveView module that does not exist yet | create the module, or don't add the route yet |

That last one is emitted from `ConsensusWeb.Router.__checks__/0` and **fails
`mix compile --warnings-as-errors`**, so a `live` route and its module must land in the
same change. Every module `router.ex` names does exist on disk today (`HomeLive`,
`AdminLive.Users`, `GroupLive.{New,Options,Review,Share}`,
`UserLive.{Login,Registration,Confirmation,Settings}`), so seeing this warning means you added a
route ahead of its module. `ConsensusWeb.AdminLive.HomePage` is gone (D-027) — do not add it
back to this list.

The other one worth recognising, because it appears the moment a context function changes
arity and a caller has not caught up:

```
warning: Consensus.Accounts.set_admin/2 is undefined or private. Did you mean:

      * set_admin/3
```

The "Did you mean" list is generated from the real module, so trust it over your memory of
the signature — this codebase is being written concurrently and arities move.

Verified in this repo (2026-08-08): `MIX_ENV=test mix compile --warnings-as-errors` exits
0 and `mix format --check-formatted` exits 0.

## Debugging with IEx

```bash
export PATH="/opt/homebrew/bin:$PATH"
iex -S mix phx.server     # app + endpoint on http://localhost:4000, code reload on
iex -S mix                # app, no endpoint
MIX_ENV=test iex -S mix   # test config (sandbox pool — check out a connection first)
mix run script.exs        # one-shot script with the app started
mix run --no-start s.exs  # compile + run without booting the supervision tree
```

Inside the shell:

- `recompile` — picks up `lib/` edits without restarting. It does **not** re-read
  `config/*.exs`; restart for config changes.
- `h Consensus.Accounts.set_admin` / `i value` / `open Mod` / `source Mod`.
- `dbg(expr)` prints the expression, its value, and each pipe stage.
  `require IEx; IEx.pry()` in code + `iex -S mix` to break.
- Prefer `/admin/dashboard` (LiveDashboard, admin-only, mounted in every env) over
  `:observer.start()`, which needs wx.
- Dev emails land at `/dev/mailbox` (`config :consensus, dev_routes: true`).
- One-shot probing without a REPL: write a `.exs` to the scratchpad and `mix run` it.

## Common failure modes

Each of these was reproduced in this repo or a copy of it.

**The suite is green.** `MIX_TEST_PARTITION=final mix precommit` → `438 passed` (2026-08-08),
format and `--warnings-as-errors` clean. A failure you see that is not in code you just
touched is most often one of two things: another process running the suite on the same
unpartitioned database, or a file being edited underneath you. Check both before believing
covers fixing. If you hit something *else* below, it is a change you just made, not a
pre-existing state of the repo. Re-run `mix test` for a current count rather than trusting
either number here.

### A named CHECK constraint only maps back to a changeset if the names match

Worth understanding before you add any constraint, because the failure is silent until runtime.
The worked example used to be the home page's singleton-row CHECK; `Consensus.Content`,
`Consensus.Content.HomePage` and `test/consensus/content_test.exs` are all deleted (D-027), but
the migration that created the CHECK (`priv/repo/migrations/20260808040000_create_home_page.exs`)
is still on disk unchanged — migrations are never edited after they ship — and the lesson is
general, not specific to that table. See the `sqlite` skill for the full DDL-side worked example
(including the new lesson about a `down/0` that recreates it); here is the Ecto/changeset half.

The migration writes the table as literal SQL through `execute/2` — `Ecto.Migration.constraint/3`
would compile to `ALTER TABLE ADD CONSTRAINT`, which SQLite rejects — and gives the CHECK an
explicit name:

```sql
"id" INTEGER PRIMARY KEY
  CONSTRAINT "home_page_is_a_singleton" CHECK ("id" = 1),
```

A schema's `changeset/2` would close with the matching `check_constraint(:id, name:
:home_page_is_a_singleton)` — **the two names have to be identical or the mapping does not
happen**, because SQLite reports whatever the DDL named and `ecto_sqlite3` passes that string
through verbatim as `[check: name]`
(`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3/connection.ex:156-160`). Verified on SQLite 3.51.0:

```
"id" INTEGER PRIMARY KEY CHECK ("id" = 1)
  → CHECK constraint failed: id                        <- the *column* name

"id" INTEGER PRIMARY KEY CONSTRAINT "home_page_is_a_singleton" CHECK ("id" = 1)
  → CHECK constraint failed: home_page_is_a_singleton   <- the constraint name
```

With the names lined up, a changeset insert of a second row degrades to
`{:error, #Ecto.Changeset<errors: [id: {"is invalid", [constraint: :check, constraint_name:
"home_page_is_a_singleton"]}]>}` instead of raising. An insert that bypasses the changeset
(`Repo.insert!/1` on a bare struct) still raises `Ecto.ConstraintError`, as it should — and
**if you ever see two constraint-name lists disagree** in that error's output (the name the
database reported vs. "The changeset defined the following constraints"), that is a naming
mismatch, not a missing declaration. Same shape for `unique_constraint` and
`foreign_key_constraint`. Note that `FOREIGN KEY constraint failed` carries **no** name at all
from SQLite (`to_constraints/2` returns `[foreign_key: nil]`), so an FK error can only be matched
by field, never by name.

If a future table needs a singleton-row CHECK (or any other CHECK) again, `check_constraint/3`
in the schema's own changeset is what proves the changeset-path mapping — a bare
`Repo.insert!/1` assertion only proves the database enforces the invariant, not that the
changeset translates the failure into a readable error.

### `no such column: u0.is_admin` / `no such table: …`

```
** (Exqlite.Error) no such column: u0.is_admin
SELECT count(*) FROM "users" AS u0 WHERE (u0."is_admin" = 1)
```

The schema module has a field the database does not. Almost always: an
**already-applied migration was edited in place**. Ecto keys off the version in
`schema_migrations`, so editing the file changes nothing — this bites constantly here,
because pre-deploy the house style *is* to edit the original migration. Confirm with

```bash
MIX_TEST_PARTITION=7 mix test          # rebuilds nothing; the DB file persists
sqlite3 consensus_test7.db ".schema users"
```

Fix in test: delete your `consensus_test<N>.db*` files and rerun — the `test` alias
recreates and re-migrates from scratch — or say it explicitly:

```bash
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.drop
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.create
MIX_ENV=test MIX_TEST_PARTITION=7 mix ecto.migrate
```

Fix in dev, pre-deploy: `mix ecto.reset` (drop + create + migrate + seed), **but not while
anyone else is using this checkout** — it drops the shared `consensus_dev.db`. Post-deploy:
never edit an applied migration, write a new one.

A missing column is the loud version of this. The quiet version is a **renamed constraint**:
the schema declares `check_constraint(:id, name: :new_name)`, the stale local database still
says `old_name`, and the changeset stops mapping the violation — so you get a raised
`Ecto.ConstraintError` where a test expected `{:error, changeset}`. CI never sees it, because
CI always starts from an empty database. Same cause, same fix; the `sqlite` skill has the
full symptom.

### `** (Ecto.ConstraintError)`

```
constraint error when attempting to insert struct:
    * "users_username_index" (unique_constraint)
If you would like to stop this constraint violation from raising an
exception and instead add it as an error to your changeset, please
call `unique_constraint/3` on your changeset with the constraint
`:name` as an option.
The changeset has not defined any constraint.
```

You inserted a raw struct (or a changeset lacking the matching
`unique_constraint/foreign_key_constraint/check_constraint`). The DB rejected it and Ecto
had nowhere to attach the error. Fix: go through the schema's changeset —
`User.registration_changeset/3` already declares `unique_constraint(:username)` and
`unique_constraint(:email)`. Add the missing `*_constraint` if a new index appears.

### `** (Ecto.NoResultsError)`

```
expected at least one result but got none in query:
from u0 in Consensus.Accounts.User,
  where: u0.id == ^999999
```

`Repo.get!/2` / `Repo.one!/2` on a missing row. Deliberate for user-facing 404s; if the
caller should handle absence, use the non-bang form and match on `nil`
(`Consensus.Activities.get_group_by_slug/1` does exactly that, for a public join link that has
to answer "no such group" rather than raise on a guest's typo).

### `** (Ecto.InvalidChangesetError) could not perform insert because changeset is invalid.`

The error body prints `Errors`, `Applied changes`, `Params`, and the whole changeset —
read the `Errors` map, e.g.
`password: [{"should be at least %{count} character(s)", [count: 12, …]}]`.
Cause is usually a `Repo.insert!/1` on an unvalidated changeset. Use `Repo.insert/1` and
match `{:error, changeset}`.

### `(MatchError) no match of right hand side value: {:error, #Ecto.Changeset<… errors: [password: {"can't be blank"…}, username: {"can't be blank"…}]>}`

From a fixture or a test that builds registration attrs by hand. This app's
`registration_changeset/3` requires `:email`, `:username` **and** `:password` (it does
magic-link *and* password registration — see the moduledoc on `Consensus.Accounts.User`).
`AccountsFixtures.valid_user_attributes/1` already supplies all three; use it rather than
assembling a map. Note `valid_user_password/0` is `"hello world!"` — 12 characters,
exactly `User.min_password_length/0`. Do not shorten it.

### A mailer failure that does *not* crash the caller

`Consensus.Accounts.UserNotifier`'s private `deliver/3` wraps `Mailer.deliver/1` in an equally
private `safe_deliver/1` with a bare `catch kind, reason -> {:error, {kind, reason}}`, so both
Swoosh failure signals — an `{:error, _}` tuple **and** a process exit — come back as a
logged `{:error, reason}`. That is deliberate: the app ships without a mail provider, and
`config/runtime.exs` pins `Swoosh.Adapters.Logger` in `:prod` precisely because the
generated `Swoosh.Adapters.Local` exits in a release (`config :swoosh, local: false`
means its storage GenServer is never started), which used to take the registering
LiveView down with it.

Consequence for you: **`deliver_*` returning `{:error, _}` is normal and must not be
matched with `=` in application code.** `AccountsFixtures.extract_user_token/1` does
match `{:ok, captured_email}`, which is correct only because `config/test.exs` uses
`Swoosh.Adapters.Test`. `test/consensus/accounts/user_notifier_test.exs` is the
regression guard; its `ExitingAdapter` and `FailingAdapter` are the two shapes to test
against.

### `module Consensus.Foo is not available` at runtime

The module was never compiled (wrong filename/namespace), or it is `test/support/`
code being used outside `MIX_ENV=test` (`elixirc_paths/1` only adds `test/support` for
`:test`), or you are in a stale IEx session — try `recompile` first.

### `warning: … is undefined or private` failing `mix compile --warnings-as-errors`

Under this repo's `precommit`, every warning is fatal. Do not silence with `_` or a
`@compile` attribute; fix the call. If the callee genuinely does not exist yet, the
router-route rule above applies: land the module in the same change.

### Formatting — or `mix.lock` — diffs appearing out of nowhere

`mix precommit` runs the *fixing* form of two tasks, `format` and `deps.unlock --unused`.
Both edit files in place and exit 0, so `precommit` can leave changes in your tree that
you did not write:

| After `precommit` you see | Who wrote it | What to do |
|---|---|---|
| unrelated `.ex`/`.exs`/`.heex` reformatting | `mix format` cleaning up code someone committed unformatted | commit it; it is what `mix format --check-formatted` in CI demands |
| `mix.lock` entries removed | `mix deps.unlock --unused` dropping deps no longer in `deps/0` | commit it; CI's `mix deps.unlock --check-unused` fails otherwise |

Run `mix format --check-formatted` and `mix deps.unlock --check-unused` (both read-only,
both exit non-zero rather than editing) *before* you start, so you know whose diff it is.

## Fast checks before you hand work off

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/aheld/Projects/consensus_app
mix compile --warnings-as-errors
mix format --check-formatted
MIX_TEST_PARTITION=7 mix test     # own DB file; or add test/consensus/accounts_test.exs
MIX_TEST_PARTITION=7 mix precommit  # the local gate (rewrites files, runs in :test)
```

Expect the count of the day: 964 tests, 0 failures as of 2026-08-09. Re-run rather than
trusting that number — the count grows as the app is written — but a failure is a real
signal, not background noise, provided you partitioned the database.

**`mix precommit` inherits `MIX_TEST_PARTITION` like any other mix invocation.** An alias is
just a list of tasks run in the same OS process, and `config/test.exs` reads the variable with
`System.get_env/1` at config time, so `MIX_TEST_PARTITION=7 mix precommit` runs the whole gate
— including its `test` step's `ecto.create` / `ecto.migrate` — against `consensus_test7.db`.
Export your digit once for the session and every command above, `precommit` included, lands on
your own file. There is no need to run the steps individually or to save `precommit` for last.

Verified 2026-08-08 with every `consensus_test*` file removed first:
`MIX_TEST_PARTITION=44 mix precommit` created only `consensus_test44.db`,
`consensus_test44.db-shm`, `consensus_test44.db-wal` — `consensus_test.db` was never created,
so the partition isolation holds. **It did not go fully green**, though: `precommit`'s `test`
step surfaced the same one pre-existing failure `mix test` does (see "Common failure modes"
above), so `precommit`'s overall exit code was non-zero on an otherwise-clean tree at the time
of writing. Don't take "precommit failed" as proof your change broke something without first
checking whether it's this same known test. (The partition-file behaviour is the durable fact
in this paragraph; do not quote a pass/fail count from it — it is the same suite `mix test`
runs, and both move.)

Delete your `consensus_test<N>.db*` files when you are done; `.gitignore` covers them
(lines 39–40, `*.db` and `*.db-*`) but they are still clutter.

### `mix precommit` is not CI

`precommit` is a **subset**, and two of its four steps are fixers rather than checkers. CI
is [.github/workflows/ci.yml](../../../.github/workflows/ci.yml), two jobs that must both
go green before `fly-deploy.yml` will deploy. Transcribed from the workflow:

**Job `test`** — `runs-on: ubuntu-latest`, matrix Elixir **1.20.3** / OTP **29.0.5**
(kept in step with the `ELIXIR_VERSION` / `OTP_VERSION` args in the `Dockerfile`), with
`MIX_ENV=test` set at the workflow level. In order:

| # | Step | Command |
|---|---|---|
| 1 | Checkout | `actions/checkout@v5` |
| 2 | Set up Elixir | `erlef/setup-beam@v1` |
| 3 | Restore cache | `actions/cache@v4` over `deps` + `_build`, keyed on `hashFiles('**/mix.lock')` |
| 4 | Install dependencies | `mix deps.get --check-locked` |
| 5 | Check that `mix.lock` has no unused entries | `mix deps.unlock --check-unused` |
| 6 | Check formatting | `mix format --check-formatted` |
| 7 | Compile without warnings | `mix compile --warnings-as-errors` |
| 8 | Run tests | `mix test` |

**Job `docker` — it is not a build-only job, and describing it as one is the mistake this
file has made repeatedly.** It runs in parallel with `test` and has five steps:

| # | Step | What it does |
|---|---|---|
| 1 | Checkout | `actions/checkout@v5` |
| 2 | Buildx | `docker/setup-buildx-action@v3` |
| 3 | Build the release image | `docker/build-push-action@v6`, `context: .`, `push: false`, **`load: true`**, **`tags: consensus:ci`**, `cache-from/to: type=gha`. `load: true` is what puts the image in the local daemon so the next two steps can *run* it. |
| 4 | Boot the release image and smoke test it | boots the image against a tmpfs `/data` and makes five assertions — below |
| 5 | Boot twice on one volume, migrating a populated database | boots twice against one real Docker volume — below |

Plus `Release logs` (`docker logs` for all three containers, `if: always()`) and a teardown
step. The step costs the job roughly 30–60 s.

**Why this matters more than the build.** `mix test` never starts a release, and
`elixirc_paths(:test)` means `mix compile` does not even compile `*_test.exs`. Steps 4 and 5
are therefore the **only** thing in the repo that exercises the boot-time
`{Ecto.Migrator, …}` child, `Consensus.Seeds`, `Consensus.BootCheck.run!/0` and the
`config_env() == :prod` half of `config/runtime.exs`. A build-only job is what let a
`/health` regression deploy green.

Step 4, in order:

1. `PHX_HOST` is **read out of `fly.toml`** with `sed`, not hardcoded, and fed to the
   container.
2. `docker run -d` with `--tmpfs /data:rw,mode=0750,uid=65534,gid=0` — that uid/gid is how Fly
   presents an *empty* volume to a release running as `nobody`. Do not "fix" a failure here by
   running the container as root; a root-owned `/data` is exactly what `Consensus.BootCheck`
   exists to reject.
3. Polls `GET /health` on `127.0.0.1` for up to 60 s, requiring the body `ok`.
4. `GET /health` **again under `Host: $phx_host`**, expecting 200.
5. A real **LiveView websocket upgrade**, expecting **101**.
6. `count_admins() == 1` over `docker exec … /app/bin/consensus rpc`.
7. Breaks the schema over `rpc` (`ALTER TABLE users RENAME TO users_gone`) and requires
   `/health` to answer **503**.

Step 5 boots `consensus:ci` twice against one named Docker volume. Between the boots it
renames the seeded admin over `rpc` and rolls the newest migration back down with
`bin/consensus eval`, so the second boot faces a genuinely pending migration against a
*populated* `users` table. The second boot must report `/health` 200, must log `== Migrated`,
and must still show exactly one admin **still carrying the new name** — which is the
assertion that `Consensus.Seeds`' "are there zero admins?" gate is not username-based. It does
not cover a migration that has never run anywhere: the pending migration is one whose `up`
already succeeded, so a bad `down` or an `ALTER TABLE` that only fails against real rows still
slips through.

### Reproducing CI locally, completely

`mix precommit`'s four steps are not it, and neither is `docker build` on its own.

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/aheld/Projects/consensus_app

# --- job `test` (five commands; CI sets MIX_ENV=test at the workflow level) ---
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix deps.unlock --check-unused
MIX_ENV=test mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_TEST_PARTITION=7 mix test          # your own digit

# --- job `docker`, step 3: build. CI tags it consensus:ci, so use that name below. ---
docker build -t consensus:ci .

# --- job `docker`, step 4: boot it and smoke test it ---
phx_host="$(sed -n "s/^[[:space:]]*PHX_HOST[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" fly.toml | head -n 1)"
secret="$(openssl rand -base64 48)"

docker run -d --name consensus-smoke \
  --tmpfs /data:rw,mode=0750,uid=65534,gid=0 \
  -e DATABASE_PATH=/data/consensus.db \
  -e SECRET_KEY_BASE="$secret" \
  -e PHX_HOST="$phx_host" \
  -e PORT=4000 -p 4000:4000 \
  consensus:ci

# (a) /health goes 200 "ok" once the boot-time migrator has finished
until [ "$(curl -fsS http://127.0.0.1:4000/health 2>/dev/null || true)" = ok ]; do sleep 1; done

# (b) the SAME route under the deployed hostname — expect 200
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $phx_host" \
  --max-time 5 http://127.0.0.1:4000/health

# (c) a real LiveView socket handshake — expect 101
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Host: $phx_host" -H "Origin: https://$phx_host" -H 'x-forwarded-proto: https' \
  -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
  --max-time 5 'http://127.0.0.1:4000/live/websocket?vsn=2.0.0' || true

# (d) the bootstrap admin was seeded — expect 1
docker exec consensus-smoke /app/bin/consensus rpc \
  'IO.puts(Consensus.Accounts.count_admins())'

# (e) a health check that cannot fail proves nothing — expect 503
docker exec consensus-smoke /app/bin/consensus rpc \
  'Consensus.Repo.query!("ALTER TABLE users RENAME TO users_gone")'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health

docker rm -f consensus-smoke
```

Three things about that block are load-bearing and easy to get wrong:

- **`-e PHX_HOST=localhost` is a misleading shortcut — do not use it.** `config/prod.exs`
  excludes `localhost` and `127.0.0.1` from `force_ssl` by **host**, so a 200 from `/health`
  under that `Host` would stay 200 even if `paths: ["/health"]` were deleted from the
  `exclude:`. Only assertion (b), carrying the *deployed* hostname, distinguishes the two —
  and Fly's checker sends the machine's own hostname, never `127.0.0.1`. `PHX_HOST` is also
  the endpoint's `:url` host, which `check_origin` validates the browser `Origin` against, so
  a wrong value 403s every socket upgrade while `GET /` and `/health` both keep answering 200.
- **The `|| true` on the websocket curl is not sloppiness.** On a successful upgrade the
  server holds the connection open and curl exits 28 once `--max-time` elapses; it still
  prints the status first. Under `set -e` the guard is what stops the *passing* path from
  aborting the script.
- The tmpfs `uid=65534,gid=0` matches an empty Fly volume. Dropping it and running as root
  defeats `Consensus.BootCheck` entirely.

Step 5 locally, if you are touching a migration or `Consensus.Seeds`:

```bash
docker volume create consensus-upgrade
docker run -d --name up1 -v consensus-upgrade:/data \
  -e DATABASE_PATH=/data/consensus.db -e SECRET_KEY_BASE="$secret" \
  -e PHX_HOST="$phx_host" -e PORT=4000 -p 4001:4000 consensus:ci
# …wait for /health on 4001, then rename the admin and take it down…
docker exec up1 /app/bin/consensus rpc \
  'import Ecto.Query
   {1, _} = Consensus.Repo.update_all(from(u in "users", where: u.is_admin == true),
                                      set: [username: "renamed-by-the-operator"])'
docker rm -f up1
# roll the newest migration back down in a fresh node, the way an operator would
docker run --rm -v consensus-upgrade:/data \
  -e DATABASE_PATH=/data/consensus.db -e SECRET_KEY_BASE="$secret" \
  -e PHX_HOST="$phx_host" -e PORT=4000 consensus:ci /app/bin/consensus eval \
  'Application.ensure_all_started(:ssl)
   Application.ensure_loaded(:consensus)
   {:ok, _, _} = Ecto.Migrator.with_repo(Consensus.Repo, &Ecto.Migrator.run(&1, :down, step: 1))'
docker run -d --name up2 -v consensus-upgrade:/data \
  -e DATABASE_PATH=/data/consensus.db -e SECRET_KEY_BASE="$secret" \
  -e PHX_HOST="$phx_host" -e PORT=4000 -p 4002:4000 consensus:ci
# expect: /health 200, `docker logs up2 | grep "== Migrated"`, one admin still named
#         renamed-by-the-operator
docker rm -f up2 && docker volume rm consensus-upgrade
```

What `precommit` therefore misses, and how each one fails you:

- **`mix deps.get --check-locked`** — never run by `precommit`. A `mix.lock` that is out of
  step with `mix.exs` passes locally and fails in CI at step 4.
- **`--check-unused` vs `--unused`** — `precommit` *rewrites* `mix.lock` and exits 0; CI
  *asserts* and exits 1. Commit whatever `precommit` changed.
- **`--check-formatted` vs `format`** — same asymmetry: `precommit` rewrites, CI asserts.
- **The whole `docker` job** — `precommit` neither builds nor boots the image, so every
  assertion in steps 4 and 5 above is invisible to it.

`TODO.md`'s troubleshooting table still describes the `docker` job as
`docker build -t consensus:test .` and calls CI "six checks". **That is stale** — read
`.github/workflows/ci.yml`, which is the only authority, and prefer the block above.
