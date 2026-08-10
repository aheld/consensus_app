# Technical Decisions

ADR-lite log. Newest last. Anything recorded here supersedes
[technical-roadmap-v1-draft.md](technical-roadmap-v1-draft.md), which is an unratified first pass.

Format: one entry per decision. Status is `settled`, `provisional`, or `superseded`.

---

## D-001 — Product scope is ratified; technical stack is not

- **Date:** 2026-08-07
- **Status:** settled

`docs/PRD.md` is accepted as the product north star: personas, functional requirements, MVP/Post-MVP split, and success metrics are not up for re-litigation without an explicit decision here.

`docs/technical-roadmap-v1-draft.md` is retained as a reference proposal only. Its stack picks (NestJS, Socket.io, self-managed Redis, Render/Fargate, an 18-week three-phase schedule) are treated as *one candidate*, not the plan. No code should be written against it until the corresponding decisions are logged here.

**Open for revision:** frontend framework, backend shape (dedicated API service vs. serverless routes), realtime transport, database host, caching strategy, hosting, and the phase schedule. See [open-questions.md](open-questions.md).

---

## D-002 — The PRD carries no technical implementation decisions

- **Date:** 2026-08-07
- **Status:** settled

`docs/PRD.md` (v2.0 → v3.0) was reduced to product content only: what the product must do, for whom, and how success is measured. Removed: the PWA/React/Next.js/Postgres-with-Supabase-Realtime stack proposal (§4), named vendor integrations inside requirements (Google Places, Yelp, OpenTable, Resy, Gracenote, Fandango, Airbnb/VRBO), the Borda-vs-IRV tabulation choice, the database schema sketch with JSONB payload examples (§6), and the engineering phase diagram with technical spikes (§8).

**Why:** requirements that name a vendor or a table can't be evaluated against alternatives — the decision is already made and hidden inside the requirement. Splitting them lets the stack be revised without touching product scope, and makes the roadmap's contradictions with the PRD visible instead of latent.

**What replaced them:**
- §4 is now *Access & Distribution Requirements* — stated as constraints (no install, no account, works in messaging-app in-app browsers, ~10s to vote) rather than a technology.
- §5 requirements name capabilities, not integrations; "Real-time Engine" became "Live Vote State" (the user-visible property, not the component).
- §6 is now *Extensibility Requirement* — five testable conditions for activity-agnosticism, with the custom/manual free-text activity type as the floor test.
- §8 is now product-level release sequencing; only Release 1 is committed scope.

**Preserved, not deleted:** everything removed is in [prd-technical-extracts.md](prd-technical-extracts.md) at draft authority. This matters because the PRD's Supabase Realtime proposal is one side of Q-1 and would otherwise have vanished.

**Consequences:** two unratified technical drafts now exist and they conflict — the roadmap wants a self-hosted NestJS/Socket.io/Redis stack, the ex-PRD wants managed realtime. Q-1 must resolve that explicitly. Also: nothing in the repo currently specifies a stack, which is the intended state until decisions land here.

---

<!-- Append new decisions below.

## D-00N — <short title>

- **Date:** YYYY-MM-DD
- **Status:** settled | provisional | superseded by D-00M
- **Decision:** what we're doing.
- **Why:** the reasoning, including what it buys us against the PRD's invariants.
- **Alternatives rejected:** and why.
- **Consequences:** what this forecloses or obligates later.

-->

## D-003 — Stack: Phoenix LiveView on the BEAM, with SQLite

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** Elixir 1.20.3 / Erlang-OTP 29.0.5, Phoenix 1.8.9, LiveView 1.2.8, Ecto SQL 3.14.0 over SQLite via `ecto_sqlite3` 0.24.1 (`exqlite` 0.39.0). Scaffolded with `mix phx.new consensus --database sqlite3`, then `mix phx.gen.release --docker`. Deploy target is a single Fly.io machine (D-012).

**Why:** the PRD's hard requirements are a shared link, live vote state without a refresh, and a hard deadline that locks voting on its own. LiveView gives server-rendered realtime over a websocket with no client state layer and no separate API, which collapses Q-1 (one deploy target or two) and Q-2 (realtime transport) into a single answer — the framework's default rendering path *is* the realtime path. Phoenix.PubSub is in the supervision tree already, which answers Q-3: no Redis, for either fan-out or caching. Sessions are 4–7 people for a few hours; a BEAM process per session is the natural fit and needs no external broker.

SQLite because the entire dataset is small, short-lived, and read-mostly, and because a file on a mounted volume removes a managed-database dependency and its bill from the MVP.

**Alternatives rejected:**
- The roadmap draft's NestJS + Socket.io + Redis + Postgres split (`technical-roadmap-v1-draft.md`) — three services and a broker to deliver vote counts to seven people. That was the draft's own Risk #2.
- The ex-PRD's Next.js + Postgres + Supabase Realtime proposal (`prd-technical-extracts.md`) — still two deploys and a vendor holding the realtime path.
- Short polling — moot once the transport is a websocket the framework already opens.
- Postgres — defensible, but it buys concurrency the traffic shape does not need, at the cost of a hosted database.

**Consequences:**
- The version floor in [mix.exs](../mix.exs) is `elixir: "~> 1.17"`, while [Dockerfile](../Dockerfile) and CI pin `ELIXIR_VERSION=1.20.3` / `OTP_VERSION=29.0.5`. The pins are the real contract; the `~>` is generator default.
- SQLite serialises writes, and the whole app is one machine with one volume. That is a deliberate ceiling, not an oversight — see D-012 and D-013.
- This supersedes the "**Open for revision:** frontend framework, backend shape … realtime transport, database host, caching strategy" clause of D-001. D-001's product half stands unchanged.
- Q-1, Q-2 and Q-3 in [open-questions.md](open-questions.md) are answered by this entry. Everything else there is still open.
- Recorded after the fact: the foundation described in D-003 through D-013 was built before this log caught up with it. Three source files ([lib/consensus/application.ex](../lib/consensus/application.ex), [fly.toml](../fly.toml), [priv/repo/migrations/20260808033720_create_users_auth_tables.exs](../priv/repo/migrations/20260808033720_create_users_auth_tables.exs)) already point readers at this file for their rationale. These entries are what they were pointing at.

---

## D-004 — Authentication is `mix phx.gen.auth` with a username and a password at sign-up

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** Run the official `mix phx.gen.auth Accounts User users` generator (Phoenix 1.8 scopes, magic link, sudo mode) and extend it in exactly three places:
  1. A `username` column — `NOT NULL`, `COLLATE NOCASE`, unique index. Validated 3–30 characters against `~r/^[a-zA-Z0-9_-]+$/` in `Consensus.Accounts.User.username_changeset/3`.
  2. Log-in accepts username **or** email in one field (`user[login]`). `Consensus.Accounts.get_user_by_login/1` routes on whether the string contains `@`.
  3. Registration takes a password (username + email + password) and signs the new user in immediately, by handing the form off to `ConsensusWeb.UserSessionController` via `phx-trigger-action` posting to `~p"/users/log-in?_action=registered"`.

**Why:** the generator is the maintained, reviewed implementation of session tokens, sudo mode, and timing-attack-safe password checks; hand-rolling any of that is strictly worse. The additions are the minimum that makes the app usable on a fresh deploy: the generator's magic-link-only registration means **no email provider, no way in**, and this deployment ships with no mail *provider*. It does have a mail *adapter*: [config/runtime.exs](../config/runtime.exs) pins `Swoosh.Adapters.Logger` for `:prod` (D-014), so a delivery returns `{:ok, _}` and logs the recipient — and nothing reaches anybody. (The generated default was worse than "delivered nowhere": `Swoosh.Adapters.Local` in `config/config.exs` plus `config :swoosh, local: false` in `config/prod.exs` made every release delivery *exit*. That is D-014's subject.) A password at sign-up is what makes the app usable regardless — nobody is ever blocked waiting on an email. `username` exists because the app has a bootstrap admin identity that should not be an email address, and because `COLLATE NOCASE` plus a unique index makes "Aheld" and "aheld" the same account at the database level rather than by convention.

**Alternatives rejected:**
- Magic-link-only, as generated — unusable without a mail provider; it puts a working SMTP setup in front of the very first log-in.
- A third-party identity provider — an account and a bill for an app whose end state has *zero* accounts for the people who matter (PRD invariant 1: voters never see a signup).
- Case-folding usernames in application code — leaves the invariant unenforced against migrations, seeds, and console sessions.
- A separate `/users/log-in-with-username` route — two forms for one concept.

**Consequences:**
- Magic-link login is retained and works, but is not a usable production path until a mail *provider* is configured in `config/runtime.exs` (D-014). Do not describe it as one.
- Registering with a password creates unconfirmed accounts that hold a password, which is precisely the case D-005 exists to handle.
- `Consensus.Accounts.create_user/2` is the deliberate back door past the registration form (it additionally casts `:is_admin` and `:confirmed_at`); it is used only by `Consensus.Seeds`.
- None of this applies to guest voters. When the voting engine is built, participants are not `users` — see Q-4 and Q-11 in [open-questions.md](open-questions.md), both still open.

---

## D-005 — Confirming a password-holding account by magic link requires an authenticated session (superseded by D-015, then D-017)

- **Date:** 2026-08-08
- **Status:** **superseded by D-015, and finally by D-017** — the refusal described below is gone, and so is the second argument it introduced. The threat model it documents still stands; read D-017 for what the code actually does.
- **Decision (superseded — see D-015, then D-017; the arity below is history, the function is `/1`):** `Consensus.Accounts.login_user_by_magic_link/2` takes the current session's user as its second argument. When the token resolves to a user with `confirmed_at: nil` **and** a non-nil `hashed_password`, the account is confirmed only if the caller is already authenticated as that same user; otherwise it returns `{:error, :not_confirmed}`.

> **Superseded.** `{:error, :not_confirmed}` no longer exists anywhere in `lib/` — the atom was removed with the behaviour. D-015 replaced the refusal with confirm-and-discard-the-password, and D-017 then removed the last remnant of this entry's mechanism. What survives is **only the threat model** below (credential pre-stuffing). The second argument is gone too: the function is `Consensus.Accounts.login_user_by_magic_link/1`, the generator's arity, and it takes no session or current-user argument at all. Everything stated about the refusal, and every mention of a second argument anywhere in this entry, is history.

**Why:** this is the credential-pre-stuffing guard described in the "Mixing magic link and password registration" section of `mix help phx.gen.auth`, and D-004 is exactly the situation that section warns about. Without it: an attacker registers `victim@example.com` with a password of their choosing; the account sits unconfirmed; the real owner later requests a magic link and confirms it; the attacker's password is now a working credential on a confirmed account. Requiring an existing authenticated session for that one transition closes it.

**Alternatives rejected:**
- Dropping the password from registration to sidestep the whole case — that is D-004's rejected option, and it costs a working log-in on a mail-less deploy.
- Confirming anyway and forcing a password reset — still hands the attacker a window, and there is no mail path to deliver the reset. **D-015 adopted the neighbouring option this one missed: confirm and *discard* the password outright, which leaves no window at all and needs no reset mail.**
- Deleting an unconfirmed account when a magic link is requested for it — turns the flow into a way to destroy other people's pending registrations.

**Consequences (superseded — see D-015):**
- The ordinary path is unaffected, because registration logs the new user in immediately (D-004) — the session that would need to confirm is already the right one.
- A user who registers, logs out without confirming, and then clicks a magic link gets `{:error, :not_confirmed}` and must log in with their password first. That is the intended trade. **No longer true: the current code (D-015 as amended by D-017) confirms them, logs them in, and discards the password. Nobody is ever told to "log in with their password first", and no call site passes a current user to check against — there is no second argument to pass one through.**
- The behaviour is load-bearing security, not an implementation detail: it is covered in [test/consensus/accounts_test.exs](../test/consensus/accounts_test.exs) and [test/consensus_web/live/user_live/confirmation_test.exs](../test/consensus_web/live/user_live/confirmation_test.exs), and must not be "simplified" away. **Still true of the D-015 behaviour that replaced it, in the same two test files.**

---

## D-006 — Authorization is one `is_admin` boolean, enforced in three places

- **Date:** 2026-08-08
- **Status:** settled — **extended by D-021**, which adds a sudo-mode requirement and an audit log to the two `Accounts` writes described here. Nothing below is wrong; it is incomplete without D-021.
- **Decision:** `users.is_admin` — a `NOT NULL` boolean defaulting to `false`. No roles table, no permissions table. It is enforced at three layers:
  1. The `:require_admin_user/2` plug in the `/admin` router pipeline (rejects the HTTP request).
  2. The `{ConsensusWeb.UserAuth, :require_admin}` `on_mount` hook on the live_session (rejects the LiveView websocket mount, for which no plug pipeline runs).
  3. The context function head itself — `Consensus.Content.update_home_page/2` matches `%Scope{user: %User{is_admin: true}}`, so a non-admin caller raises `FunctionClauseError` rather than writing. It then re-reads the actor's role via `Accounts.get_user/1` and returns `{:error, :unauthorized}` for an admin demoted since mount; a `%Scope{}` handed in by a LiveView is a snapshot taken at mount time. (No transaction there — it is one non-destructive `Repo.update` on one row, with no count to keep consistent, unlike `set_admin/3` below.)

  `Consensus.Accounts.set_admin/3` — the **actor's `%Scope{}` is the first argument**, then the target user, then the boolean — refuses to revoke the last admin, returning `{:error, :last_admin}`. The check and the write share one `Repo.transact/1`, and *both* the target and the actor's own role are re-read from the database inside it, because a LiveView holds the scope it mounted with (D-016; that entry is where the arity went from 2 to 3, and where the returned session tokens for `UserAuth.disconnect_sessions/1` came from). A caller with a non-admin or `nil` scope gets `{:error, :unauthorized}`. Role changes go through `User.admin_changeset/2`, which casts `:is_admin` and nothing else. **Since D-021 both `set_admin/3` and `delete_user/2` also require the actor to be in sudo mode and emit an `[audit]` log line** — read that entry alongside this one.

**Why:** there are two kinds of person in this application — the operator and everyone else. A roles table would be schema and joins modelling a distinction that does not exist. The triple enforcement is not belt-and-braces theatre: layers 1 and 2 guard genuinely different entry points (an HTTP request and a socket mount), and layer 3 means the rule survives a future caller that reaches the context from somewhere neither guard covers. Demoting the last admin locks the deployment out of its own admin area with no recovery path short of a console session, so the context refuses.

**Alternatives rejected:**
- A `roles` / `user_roles` table — premature; adding one later is a migration and a changeset, not a rewrite.
- Enforcing only in the router — leaves the LiveView socket mount unguarded, which is the classic Phoenix authorization hole.
- Reusing the generator's `registration_changeset` for role changes — would let an admin endpoint smuggle through an email or password change. `admin_changeset/2` casting a single field is what prevents that.
- Checking `count_admins/0` outside the transaction — a read-then-write race can demote the last admin.

**Consequences:**
- Any future admin-only write must pattern-match the scope in its function head, not just sit behind the router — **and re-read the actor's role from the database**, inside the transaction if the write is destructive or depends on a count. All three current admin writes do. If it grants or destroys authority, D-021 adds two more obligations: a sudo-mode check and an audit line. `update_home_page/2` carries neither, deliberately — editing prose is not exercising authority.
- Promotion is manual, from `/admin/users`. There is no self-service path to admin, by design.
- If richer roles ever arrive (per-session organizer permissions, say), this is the boolean they replace — a bounded migration, and the reason it stays a boolean now.

---

## D-007 — `username` and `is_admin` were folded into the generated initial migration

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** [priv/repo/migrations/20260808033720_create_users_auth_tables.exs](../priv/repo/migrations/20260808033720_create_users_auth_tables.exs) — the file `mix phx.gen.auth` generated — was edited in place to add `username` (`null: false`, `collate: :nocase`) and `is_admin` (`null: false, default: false`), plus `create unique_index(:users, [:username])`. No follow-up migration was written.

**Why:** two reasons, and the second is the hard one.

1. This schema is greenfield. It has never been deployed and no database exists that a second migration could migrate. A `create table` followed by an `alter table` against a table that has only ever existed in this repo is archaeology for a history nobody lived.
2. SQLite could not do it cleanly anyway. `ALTER TABLE … ADD COLUMN` cannot add a `NOT NULL` column without a constant default, and adding a `UNIQUE` column requires rewriting the table (create-new, copy, drop, rename). Writing that dance to reach a state the `CREATE TABLE` could have expressed directly is pure cost.

**Alternatives rejected:**
- A second migration adding the columns — the table-rewrite above, for no benefit.
- `username` as nullable with a backfill — makes "every user has a username" a convention rather than a constraint, and log-in depends on it.
- Application-level uniqueness only — `unsafe_validate_unique` races; the unique index is what actually holds. Both are present, in that order, which is the standard Ecto pairing.

**Consequences:**
- Editing a generated migration is safe **only** while nothing has been deployed. Once this ships, that door closes: every subsequent change is a new migration, and SQLite's `ALTER TABLE` limits become a live constraint on schema design. The voting-engine tables will land under that rule.
- The generator's own migration is therefore no longer byte-identical to `phx.gen.auth` output; the file carries a comment saying so.

---

## D-008 — The home page is a singleton table with a raw-SQL `CHECK (id = 1)`

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** [priv/repo/migrations/20260808040000_create_home_page.exs](../priv/repo/migrations/20260808040000_create_home_page.exs) creates `home_page` with literal `execute/2` SQL rather than `create table/2`, so the table can be declared as `"id" INTEGER PRIMARY KEY CHECK ("id" = 1)`. Column types match what `ecto_sqlite3` generates (INTEGER ids, TEXT timestamps), and the down migration is `DROP TABLE`.

**Why:** "there is exactly one home page" should be a database invariant, not a convention that holds as long as every writer remembers it. SQLite accepts `CHECK` constraints only inside `CREATE TABLE`; it rejects `ALTER TABLE … ADD CONSTRAINT`, which is exactly what `Ecto.Migration.constraint/3` compiles to. So expressing the invariant at all requires bypassing the Ecto DSL for this one statement.

**Alternatives rejected:**
- `Ecto.Migration.constraint/3` — does not work on SQLite, for the reason above.
- Enforcing singleness in `Consensus.Content` alone — no protection against a migration, a seed run, or an `iex` session inserting a second row, after which "which one is the home page" has no answer.
- A key/value settings table — more general than the problem, and the generality would be unused.

**Consequences:**
- The migration is not round-trippable through Ecto's introspection helpers; it is hand-written SQL and stays that way.
- `Consensus.Content.ensure_home_page!/0` can safely upsert row 1 on every boot (D-010) because the database will reject anything else.
- If a second piece of site-wide content ever appears, that is the moment to reconsider the shape — not before.

---

## D-009 — Migrations run at application boot; `fly.toml` has no `release_command`

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** [fly.toml](../fly.toml) contains no `[deploy]` block at all. Schema migration happens inside the supervision tree, via the `{Ecto.Migrator, repos: …, skip: skip_migrations?()}` child that Phoenix 1.8's sqlite3 generator already ships in [lib/consensus/application.ex](../lib/consensus/application.ex). `skip_migrations?/0` is `System.get_env("RELEASE_NAME") == nil`, so migrations run in a release (Docker, Fly, `bin/server`) and not under `mix phx.server`.

**Why:** Fly's own SQLite guide requires it. A `release_command` runs on a temporary machine, and — per <https://fly.io/docs/volumes/overview/> — volumes are unavailable during release-command execution. The guide states the consequence directly: the release command must be removed "because a volume may not be ready once your application release runs, so to fix this we need to run migrations on application start" (<https://fly.io/docs/elixir/advanced-guides/sqlite3/>). With SQLite, the failure is worse than a no-op: `release_command = "/app/bin/migrate"` would create and migrate a *throwaway* database file on the release machine's ephemeral disk, report success, and leave the real volume untouched — a green deploy on an unmigrated database.

Migrating in the tree ahead of `ConsensusWeb.Endpoint` also means the schema is current before the endpoint accepts a single request, which a release command cannot guarantee.

**Alternatives rejected:**
- `[deploy] release_command` — the generator/`fly launch` default, and wrong for a volume-backed database, per the citations above.
- Migrating by hand over `fly ssh console` — a deploy step that depends on a human remembering it.
- Calling `Release.migrate()` at the top of `start/2`, as the Fly guide's example shows — the guide predates Phoenix shipping the `Ecto.Migrator` child. The child is the same behaviour, supervised, with the `skip:` gate already wired.

**Consequences:**
- `rel/overlays/bin/migrate` still exists (generator output) but is not part of any deploy path.
- A migration that fails takes the boot down, which is the intended outcome — a machine serving traffic against a half-migrated SQLite file is worse than a machine that did not come up.
- `mix phx.server` deliberately does **not** auto-migrate; local schema changes go through `mix ecto.migrate` / `mix ecto.setup`.

---

## D-010 — Seeding runs in the supervision tree, and the bootstrap password bypasses the length minimum on purpose

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `{Consensus.Seeds, skip: skip_seeds?()}` sits in the supervision tree **directly after** `{Ecto.Migrator, …}`. Both run synchronously during supervisor init and return `:ignore`, so by the time the endpoint starts, the schema is current and the bootstrap admin exists. `Consensus.Seeds.run!/0` is idempotent and never modifies an existing user; it is the single entry point for all three callers (the tree, `priv/repo/seeds.exs` for `mix ecto.setup`, and `Consensus.Release.seed/0` for a manual run over `fly ssh console`).

It creates admin `aheld` / `aheld@example.com` / `adminpass`, confirmed and `is_admin: true`. `adminpass` is nine characters, below the twelve this app enforces on everyone else (`Consensus.Accounts.User.min_password_length/0`); seeding passes `validate_length: false` to get it through — **but only when the password is the built-in `adminpass`**. An operator who sets `ADMIN_PASSWORD` is held to the full twelve, because waiving it for them would silently accept a one-character production admin password. All three values are overridable with `ADMIN_USERNAME`, `ADMIN_EMAIL`, `ADMIN_PASSWORD`.

**Why:** a fresh deploy has to be reachable by its operator with no console access and no email provider (D-004), which means a documented default credential. Documented defaults are a real risk, so the weakness is paired with compensating controls rather than hidden:

- `run!/0` logs a warning on **every** boot, for as long as any admin still has the default, naming the account and stating that anyone who can reach the app can take it over. The check is `Seeds.admins_with_default_password/0`, which tests the *password*, not the username — renaming the bootstrap account does not silence it.
- `/admin/users` renders a banner for as long as the default is in place, driven by `Consensus.Seeds.default_password_in_use?/0`.
- `ADMIN_PASSWORD` set before the first boot (`fly secrets set ADMIN_PASSWORD=…`) means the default never exists on that deployment.

Placement after `Ecto.Migrator` is not stylistic — seeding writes to tables the migrator just created, and both being synchronous `:ignore` children is what orders them deterministically.

**Alternatives rejected:**
- A random generated password printed to the boot log — unrecoverable if the log scrolls, and no better than a documented default once it is sitting in a log.
- Lowering `@min_password_length` to accommodate the seed — weakens every human's password to solve a bootstrap problem.
- Seeding only from `priv/repo/seeds.exs` — never runs in a release, so a Fly deploy would come up with no way in.
- No default admin, operator provisions over `fly ssh console` — one more manual step between a green deploy and a usable app.

**Consequences:**
- `validate_length: false` on `password_changeset` still enforces `min: 1, max: 72`; it relaxes the minimum, it does not remove validation. `Consensus.Seeds` is the **only** supported caller, and that is stated in the changeset's own docs.
- `default_password_in_use?/0` costs one bcrypt verification per call — admin pages only, never a hot path.
- `config/test.exs` pins `seed_on_boot: false`, because seeding behind ExUnit's back would leak a user into every `Accounts.list_users/0` assertion. `skip_seeds?/0` otherwise falls back to `skip_migrations?/0`, so seeding follows migration.
- Shipping this app to real users obligates changing the password, or setting `ADMIN_PASSWORD` first. The warning and the banner exist so that obligation cannot be forgotten quietly.

---

## D-011 — LiveDashboard is mounted in every environment, behind admin auth

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `live_dashboard "/dashboard", metrics: ConsensusWeb.Telemetry, on_mount: [{ConsensusWeb.UserAuth, :require_admin}]` inside a `scope "/admin"` piped through `[:browser, :require_authenticated_user, :require_admin_user]`. It is **not** wrapped in `Application.compile_env(:consensus, :dev_routes)`. It sits in its own `scope`/`live_session` because `live_dashboard/2` declares a live_session of its own and cannot be nested inside the `:require_admin` one.

**Why:** production is where process counts, memory, and slow queries actually matter, and this deployment is a single machine with no external observability. Gating LiveDashboard on `:dev_routes` puts the tool exclusively where it is least needed. The generated router comment itself recommends admin authentication as the alternative to the dev-only gate. The auth here is the same double guard as every other admin route (D-006), so exposure is identical to `/admin/users`.

**Alternatives rejected:**
- The generated `:dev_routes` gate — no production visibility.
- Basic auth over the dashboard — a second credential system alongside the one that already exists.
- An external APM — a vendor and a bill for a single 512 MB machine.

**Consequences:**
- LiveDashboard's exposure is as strong as `is_admin` and the session token **at mount time**. Weakening admin auth weakens this too.
- **Revocation is a separate problem, and it rests on one line.** The `:require_admin` `on_mount` hook runs once per mount, and `live_patch` between LiveDashboard pages inside the same `live_session` does not remount — so an admin demoted mid-session keeps a working dashboard socket until that socket is severed. Every write *this app* owns has a second line of defence — it re-reads the actor's role from the database at call time (D-006) — but LiveDashboard is third-party: there is no context function to re-read anything. Its only revocation is `ConsensusWeb.UserAuth.disconnect_sessions/1` being called at the demotion call site — the private `set_admin/3` helper in `ConsensusWeb.AdminLive.Users` — which forces a remount and thereby re-runs the hook. (The delete call site, the private `delete_user/2` helper in the same module, now disconnects too; see D-021.) Deleting that single line left the whole suite (240 tests at the time) green; it is now pinned by "demoting severs the demoted admin's live sockets" in [test/consensus_web/live/admin_live/users_test.exs](../test/consensus_web/live/admin_live/users_test.exs). Note the demoted user is *not* logged out — `set_admin/3` collects their session tokens without deleting them — so they remain signed in as an ordinary member, which is the intended outcome.
- `/dev/mailbox` remains dev-only under `dev_routes`, so it does not appear in a `MIX_ENV=prod` route table. The two are gated differently on purpose.

---

## D-012 — One Fly machine, one volume, never auto-stopped — with the data-loss risk accepted explicitly

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** A single machine (`shared-cpu-1x`, 512 MB, `swap_size_mb = 512`) in one region, with one volume `consensus_data` mounted at `/data` and `DATABASE_PATH = '/data/consensus.db'`. `auto_stop_machines = 'off'`, `auto_start_machines = false`, `min_machines_running = 1`. Deploys go out as `flyctl deploy --remote-only --ha=false`; `fly scale count 2` is never run. `kill_signal = 'SIGTERM'` with `kill_timeout = '30s'`; `snapshot_retention = 30`; auto-extend at 80% by 1 GB up to 10 GB.

This is also the **only** place [Dockerfile](../Dockerfile) departs from `mix phx.gen.release --docker` output — one `RUN` (plus its comments) before `USER nobody`:

```dockerfile
RUN mkdir -p /data && chown nobody:root /data && chmod 750 /data
```

When a volume is mounted empty, both Docker and Fly's init take the mount point's ownership from the image. Without that line the release starts as `nobody` against a root-owned `/data` and dies with `** (Exqlite.Error) unable to open database file`.

This entry originally quoted a `VOLUME /data` line alongside the `RUN`. **D-016 removed it**, and that `RUN` is now the entire diff against generator output — `diff` the reference generator Dockerfile against [Dockerfile](../Dockerfile) and the one added hunk is that line and its comments. See D-016 for why `VOLUME` had to go, and note that removing it does not by itself make a forgotten mount visible; the boot preflight does that.

**Why:** the constraint is physical, not a preference. Per <https://fly.io/docs/volumes/overview/>, "A Machine can only mount one volume at a time and a volume can be attached to only one Machine," and a volume is tied to the hardware of one host. A second machine gets a *different* volume and therefore a *different, silently divergent* database. `--ha=false` is what stops `fly deploy` from creating that second machine (<https://fly.io/docs/launch/continuous-deployment-with-github-actions/>).

The auto-stop settings matter more here than for a stateless app: a stopped machine drops every LiveView websocket *and* takes the database offline. The two flags must move together — auto-stop enabled with auto-start disabled produces a machine that stops and never returns. `SIGTERM` plus a 30-second timeout lets the BEAM drain connections and close SQLite cleanly (WAL checkpoint) instead of being killed mid-write. `snapshot_retention = 30` because Fly's 5-day default is not long enough to notice silent corruption over a long weekend.

**Alternatives rejected:**
- Two or more machines — produces two databases. Not a scaling option; a correctness failure.
- LiteFS for multi-region replication — the Fly guide itself frames it as "if you are okay using beta software." Not for an MVP that has not shipped.
- Managed Postgres, which would allow horizontal scaling — reopens D-003.
- Fly's default 5-day snapshot retention — too short to be a real recovery window.

**Consequences — the accepted risk, stated plainly:** Fly's volumes documentation says "Always provision at least two volumes per app. Running an app with a single Machine and volume leaves you at risk for downtime and data loss." This deployment knowingly does the thing that sentence warns against. Concretely:

- A host failure takes the app down and can lose data written since the last snapshot. Recovery is `fly volumes create <name> --snapshot-id <id>`, and the RPO is however old that snapshot is (daily, retained 30 days).
- Every deploy is a restart, and a restart is a brief outage plus every LiveView reconnecting.
- Horizontal scaling is not available at any traffic level. The only headroom is a bigger machine.

This is acceptable for a pre-launch MVP with 4–7 person sessions and no revenue. It stops being acceptable the moment real groups depend on it, and the exit is D-003's rejected option — a networked database — not a second machine.

---

## D-013 — WAL and `busy_timeout` are stated explicitly in every environment

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `journal_mode: :wal` and `busy_timeout: 5_000` are written out on `Consensus.Repo` in both [config/dev.exs](../config/dev.exs) and the production block of [config/runtime.exs](../config/runtime.exs). [config/test.exs](../config/test.exs) sets `busy_timeout: 5_000` alongside `pool: Ecto.Adapters.SQL.Sandbox`. `mix phx.new --database sqlite3` generates **none** of these lines; all three files were edited to add them.

**Why:** SQLite serialises writes, and this app is one machine with one file (D-012), so the two settings that decide what happens under write contention are load-bearing rather than incidental. WAL lets readers keep running while a write is in flight; the busy timeout makes a contended write *wait* instead of immediately returning `** (Exqlite.Error) database is locked`.

Both values happen to be `ecto_sqlite3` defaults. They are still written out, for two distinct reasons:

- **In production**, a default that is load-bearing should be visible in the config file, not inherited silently from a dependency that could change it in a minor release.
- **In dev**, the point is to match production exactly, so that "database is locked" can never be a production-only surprise — the config carries that sentence as a comment.

In test, the same timeout turns real contention between `async: true` tests into a short wait rather than a flake that looks like a bug in whichever test lost the race.

**Alternatives rejected:**
- Relying on the `ecto_sqlite3` defaults implicitly — same runtime behaviour today, but the reader of `runtime.exs` cannot tell that write contention was thought about, and a dependency bump could change it without a diff in this repo.
- Setting them in production only — makes dev a weaker test of production, which is the exact failure mode the dev.exs comment names.
- Running the test suite `async: false` — slower, and it hides contention that production still has.
- Retrying at the application layer — reimplementing, worse, what the driver already offers.

**Consequences:**
- `config/test.exs` deliberately does **not** set `journal_mode` — it runs on `Ecto.Adapters.SQL.Sandbox`, where each test is wrapped in a rolled-back transaction and the journal mode is not the thing under test.
- ~~`POOL_SIZE` (default `5`) buys concurrent *readers* only; extra pool slots cannot parallelise writes. `runtime.exs` says so in a comment.~~ **History — wrong as written, superseded by D-038.** Extra pool slots are not neutral: they manufacture contention for a lock that was never shareable, and they degrade *reads* as well. Measured on a 15-voter deadline burst — `pool_size: 5` produced a p95 of 25,762ms and lost ballots to the busy timeout, against 10.6ms at `pool_size: 1`; the read tail moved 5,431ms → 15.6ms. The default is now **`1`**. The claim that writes cannot be parallelised was correct; the inference that spare slots therefore cost nothing was not.
- Neither setting removes the single-writer constraint — that is a property of D-003 and D-012. They only decide whether contention waits or fails.
- `synchronous` was left unset here and is pinned to `:normal` by D-038 — the value it already had by default, now stated rather than inherited.

---

## D-014 — The production mailer is `Swoosh.Adapters.Logger`, and delivery can never fail a request

- **Date:** 2026-08-08
- **Status:** **partly superseded by D-039.** The *adapter* half is history: production now uses `Swoosh.Adapters.Resend` whenever `RESEND_API_KEY` is set, and falls back to `Swoosh.Adapters.Logger` only when it is not. The *never-fail-a-request* half is unchanged and still binding — it is CLAUDE.md invariant 9.
- **Decision:** `config/runtime.exs` pins `config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Logger, level: :info` for `config_env() == :prod`, ahead of the commented provider examples so a real provider still wins. `Consensus.Accounts.UserNotifier.deliver/3` wraps `Mailer.deliver/1` in a `catch`, so both an `{:error, _}` tuple and a process **exit** become a logged `{:error, reason}`. `ConsensusWeb.UserLive.Registration` no longer asserts `{:ok, _} = ` on the confirmation email.

**Why:** the generated configuration ships a live landmine that D-004 walks straight into. `config/config.exs` names `Swoosh.Adapters.Local` as the adapter, and `config/prod.exs` sets `config :swoosh, local: false` — which is what stops Swoosh's application from starting `Swoosh.Adapters.Local.Storage.Manager`. In a release, the two together mean every delivery calls a GenServer that does not exist:

```
** (exit) exited in: GenServer.call({:global, Swoosh.Adapters.Local.Storage.Memory}, {:push, %Swoosh.Email{...}}, 5000)
```

Reproduced against the built image before the fix:

```
docker exec consensus /app/bin/consensus rpc 'Consensus.Accounts.deliver_login_instructions(u, & &1)'
# => exited in: GenServer.call({:global, Swoosh.Adapters.Local.Storage.Memory}, ...)
```

An `exit` is not caught by `with`, so it propagates: sign-up — the one flow this app promises works without a mail provider (D-004) — would have crashed the LiveView in production while passing every test, because `config/test.exs` uses `Swoosh.Adapters.Test`. That is the worst shape a defect can have.

`Swoosh.Adapters.Logger` is Swoosh's documented answer for "environments where you do not necessarily want to send real emails". It always returns `{:ok, _}`, needs no process, and by default logs the *recipient only* — so no magic-link token reaches `fly logs`.

**Alternatives rejected:**
- `config :swoosh, local: true` in production — keeps mail alive but stores it in a memory process nothing can read, since the mailbox preview route is `:dev_routes` only. Silently dropping mail while claiming to deliver it is worse than logging it.
- `log_full_email: true` — puts working magic links into production logs.
- Requiring a real provider before the first deploy — reintroduces exactly the barrier D-004 removed, and TODO.md would grow a mandatory account signup at another vendor.
- Only fixing the config and leaving `UserNotifier` alone — the config fix removes today's exit, but any future adapter (a provider outage, a bad API key) can fail, and a failed confirmation email must never lose an account that has already been created.

**Consequences:**
- Delivery is best-effort everywhere. `UserNotifier` logs `could not deliver ...` at `:error` with a pointer to the runtime.exs section; that log line is the operator's signal, and it is asserted in [test/consensus/accounts/user_notifier_test.exs](../test/consensus/accounts/user_notifier_test.exs).
- That test file is a regression guard with two stand-in adapters — one that exits and one that returns `{:error, _}` — because `Swoosh.Adapters.Test` cannot reproduce either.
- Configuring a real provider is still a one-line change in `config/runtime.exs`, and it silently upgrades magic-link log-in and email-change confirmation from "logged" to "delivered".

---

## D-015 — A magic link on an unconfirmed account discards the password it finds

- **Date:** 2026-08-08
- **Status:** settled — supersedes the second half of D-005; **its own two-sub-case rule is superseded by D-017**, and its `delete_user/2` half is **extended by D-021** (sudo mode, returned session tokens, audit line)
- **Decision:** `Consensus.Accounts.login_user_by_magic_link/2` no longer refuses to confirm an unconfirmed account that holds a password. It confirms and logs the person in, and:
  - if the caller was already authenticated as that user, the password is kept;
  - otherwise the password is **discarded** (`User.confirm_and_clear_password_changeset/1`), and the flash says so.

  `ConsensusWeb.AdminLive.Users` additionally gained a **Delete** action, backed by `Accounts.delete_user/2`: an admin may delete a non-admin account that is not their own, which frees the email address and username.

> **Amended by D-017.** The *direction* of this entry is the current behaviour and the reasoning below still holds — but the two sub-cases above do not. The signed-in carve-out was removed: `Consensus.Accounts.login_user_by_magic_link/1` (arity **1**, no session argument) discards the password **unconditionally**. Read D-017 for why keeping it was unsound. Everywhere below that says "if the caller was already authenticated", "current user", or `/2`, read "always" and `/1`. The `delete_user/2` half of this entry is unaffected and still current.

**Why:** D-005 implemented only the first half of the guidance in `mix help phx.gen.auth`. The full sentence is: *"If they don't have a password (because it was set by the attacker), then they can set one via a 'Forgot your password?'-like workflow."* D-005 built the guard and not the workflow, and the result was strictly worse than the reference app on recoverability:

- registration always sets a password and leaves `confirmed_at: nil`;
- nothing gates on `confirmed_at`, so accounts stayed unconfirmed indefinitely;
- with no mail provider (D-014) no magic link is ever delivered anyway;
- so the magic-link function returned `{:error, :not_confirmed}` for every non-seed account, forever;
- and the unique index on `users.email` then stopped the person re-registering.

One forgotten password destroyed an account **and** burned its email address, with no remedy short of a remote IEx session. The reference app has no such hole: it sets no password at registration, so the magic link *is* the recovery path.

Discarding the password is a better answer than refusing, and it defeats the attack more completely than D-005 did. Whoever can read the inbox is the owner; a password set before the address was ever confirmed proves nothing. After this change the pre-stuffing attacker does not merely fail to gain a confirmed account — their credential stops working the moment the real owner clicks the link. The owner lands in sudo mode (they have just authenticated) and can set a password immediately from Settings.

`delete_user/2` exists because the magic-link path still needs a mail provider, and this app ships without one. The admin area is the recovery lever a mail-less deployment actually has.

**Alternatives rejected:**
- Keeping `{:error, :not_confirmed}` — the status quo this entry exists to fix.
- Auto-confirming at registration — reopens credential pre-stuffing in full: the attacker's account would be confirmed, so the owner's later magic-link login would leave the attacker's password working.
- A dedicated `/users/reset-password` route with its own token — more surface for the same outcome the magic link already delivers, and equally dependent on a mail provider.
- Letting an admin reset a password to a value they choose — an admin who can read a password they set for someone else is a worse position than an admin who can delete an account.

**Consequences:**
- Callers must expect a `%User{hashed_password: nil}` back. `ConsensusWeb.UserSessionController` detects it and flashes "the password that was set on this account has been removed", and `UserLive.Confirmation` warns *before* the button is pressed. (Under D-017 that warning fires for a signed-in owner too, since `@clears_password?` is now computed from the user alone.)
- A user who registers, logs out without confirming, and then uses their own magic link loses the password they chose. That is the same trade every magic-link-as-reset system makes, and the UI states it up front.
- `delete_user/2` refuses to delete an administrator (demote first) or the actor themselves. Session tokens go with the row via `ON DELETE CASCADE` and `home_page.updated_by_id` is nulled by `ON DELETE SET NULL`; SQLite enforces both — `PRAGMA foreign_keys` is on, verified. **Since D-021 it also requires sudo mode and returns `{:ok, {user, tokens_to_disconnect}}`** — the tokens collected before the delete, since the cascade takes them — so the caller can sever an already-mounted LiveView. Any document still saying the delete path does not disconnect is out of date.
- Covered by [test/consensus/accounts_test.exs](../test/consensus/accounts_test.exs) (including an end-to-end pre-stuffing scenario) and [test/consensus_web/live/user_live/confirmation_test.exs](../test/consensus_web/live/user_live/confirmation_test.exs).

---

## D-016 — Boot fails loudly when the volume is not writable, and both authorization layers are asserted

- **Date:** 2026-08-08
- **Status:** settled — **change 1 is amended by D-022**: the file probe now covers the whole WAL set, and `Consensus.Release.rollback/2` preflights too. Change 4's `/health` claim was already corrected by D-018.
- **Decision:** Four hardening changes that came out of adversarial review:
  1. `Consensus.Application.start/2` preflights the SQLite file in a release, before `Consensus.Repo` enters the supervision tree, by calling **`Consensus.BootCheck.run!/0`** ([lib/consensus/boot_check.ex](../lib/consensus/boot_check.ex)). It (a) creates the directory `DATABASE_PATH` points into if it is missing and raises — naming the directory's uid/gid/mode and the `fly ssh console -u root -C "chown -R 65534:0 /data"` remedy — if it cannot be written; (b) raises the same way if an *existing* database **file** cannot be opened for append, which is the case a directory-only probe misses when someone writes into the volume as root over `fly ssh console` — **D-022 widened this to every existing member of the WAL set (`DATABASE_PATH`, `-wal`, `-shm`) and made the message name the path that refused**; and (c) compares the directory's device id against `/` and, when they match, **raises if `FLY_APP_NAME` is set** and logs a warning otherwise, because a writable directory is not the same as a mounted one. `Consensus.Release.migrate/0` and `Consensus.Release.seed/0` run the same preflight — they execute in a fresh node via `bin/consensus eval`, which never goes through `Consensus.Application.start/2`, and they are exactly what an operator reaches for when something is already wrong; without it they report an unwritable volume as a connection-pool error. *(History: this entry originally exempted `Consensus.Release.rollback/2`. D-022 removed the exemption — all three entry points preflight now.)*
  2. `Accounts.set_admin/3` takes the actor's `Scope`, re-reads the actor's role inside the transaction, and returns the demoted user's session tokens so `ConsensusWeb.UserAuth.disconnect_sessions/1` can cut off a LiveView that is already mounted.
  3. The `Dockerfile` no longer declares `VOLUME /data`.
  4. `[[http_service.checks]]` was added to `fly.toml` — `GET /health`, `grace_period = '15s'`, `interval = '30s'`, `timeout = '5s'`; `ci.yml` no longer triggers on `push` to main; `fly-deploy.yml` declares `permissions: contents: read`.

**Why, one by one:**

*Preflight.* The Dockerfile's `chown nobody:root /data` only takes effect when the mount is empty, because that is the only case where a container runtime copies the image directory's ownership onto the volume. A restored snapshot, a `lost+found`, or a file written during a root `fly ssh console` session all defeat it — and the failure Ecto produces is eleven `database_open_failed` lines followed by a `DBConnection.ConnectionError` about connection pools, which sends the operator looking at pool size. Three lines of `File.write` turn that into one instruction.

*Stale admin scope.* A LiveView holds the scope it mounted with. Before this, an admin who had just been demoted could still promote people from a tab they already had open, permanently. Re-reading the actor inside the transaction closes it even if the disconnect is missed, and the disconnect closes it promptly.

*`VOLUME /data`.* It made Docker invent an anonymous volume for a plain `docker run`, so a run with **no** `-v` looked durable while writing to a throwaway. That is exactly the misconfiguration `fly.toml` calls fatal, and it made the local durability check meaningless. That is the whole of the reason, and it is sufficient.

What removing `VOLUME` does **not** buy is visibility: the Dockerfile's own comment says "Without it, forgetting the mount fails visibly", and that is false. The `RUN mkdir -p /data` on the line above means `/data` exists and is writable whether or not anything is mounted there, so a container started with no `-v` boots clean, passes the write probe, migrates, seeds a default-password admin, and writes to storage that dies with the container. Nothing fails. The visibility comes from `Consensus.BootCheck.on_root_filesystem?/1` in [lib/consensus/boot_check.ex](../lib/consensus/boot_check.ex) — the device-id check in change 1 above — which is what actually says the directory is part of the container filesystem and the database will not survive the next deploy. Do not let that Dockerfile comment stand in for the preflight when reasoning about this.

On Fly specifically (`FLY_APP_NAME` set) that condition is now **fatal**, not a warning. There is no legitimate reason for `DATABASE_PATH` to sit outside the mount there, the database is empty by definition at that point, so failing the deploy costs nothing and is strictly preferable to discovering it after the *next* deploy has destroyed real data. The warn-only behaviour is retained off Fly, so a `docker run` with no `-v` still boots for a quick look at the image.

*CI.* `push: [main]` on `ci.yml` plus `fly-deploy.yml` calling it as a reusable workflow meant every merge ran the whole matrix and the Docker build twice.

**Alternatives rejected:**
- Fixing the ownership problem with a root entrypoint that chowns and drops privileges — a larger surface, and it puts root back in the image for a case that a clear error message resolves in one command.
- Trusting `Repo.get` to reject an out-of-range id — exqlite raises on a 26-digit integer rather than returning `nil`, which is why `Accounts.get_user/1` bounds it.
- Leaving the health check out because the deploy smoke test exists — that watches for ten seconds and then stops watching.
- Pointing the check at `/` — Fly's checker connects over plain HTTP on the machine's private address, and `force_ssl` in `config/prod.exs` 301-redirects everything not on its exclusion list, so a check on `/` could never return 200. `ConsensusWeb.HealthController` answers `/health`, sits outside the `:browser` pipeline, and is on that `force_ssl` exclusion list. **What the endpoint actually proves is D-018's subject** — the `SELECT 1` this entry originally shipped was not enough, and the claim that it caught a missing volume was false as written.

**Consequences:**
- `set_admin/3` is a breaking signature change from `set_admin/2`. Fixtures write the first admin's role directly, because there is no admin actor to authorise the very first one.
- `test/consensus_web/router_test.exs` asserts that every `/admin` route carries both guards. `Phoenix.Router.__routes__/0` does not expose `pipe_through`, so the plug half is asserted against the router source; the comment in that file says so plainly.
- A local `docker run` without `-v` now loses its data on `docker rm`, which is the honest behaviour. It is not a silent loss: `Consensus.BootCheck` logs it at boot (and, on Fly, refuses to boot at all). Run the image with `-v <something>:/data` and `DATABASE_PATH=/data/consensus.db` when the durability check is the point.
- The preflight is covered by [test/consensus/boot_check_test.exs](../test/consensus/boot_check_test.exs), which exercises all three checks against real directories under a `tmp_dir` and pins the exact wording operators grep for — including, since D-022, the `refused       : <path>` line for a root-owned `-wal` sidecar. The supervision-tree ordering that follows it is covered by [test/consensus/application_test.exs](../test/consensus/application_test.exs), against the deliberately public `Consensus.Application.children/0`.

---

## D-017 — A magic link discards the password unconditionally, and the function returns to arity 1

- **Date:** 2026-08-08
- **Status:** settled — supersedes the two-sub-case rule in D-015, and removes the last of D-005's mechanism
- **Decision:** `Consensus.Accounts.login_user_by_magic_link/1` takes a token and nothing else — the generator's arity, restored. When the token resolves to an unconfirmed account that already holds a password, it confirms the account, logs the person in, and **always** discards the password:

```elixir
{%User{confirmed_at: nil, hashed_password: hash} = user, _token}
when not is_nil(hash) ->
  user
  |> User.confirm_and_clear_password_changeset()
  |> update_user_and_delete_all_tokens()
```

  There is no surrounding `if`, no current-user argument, and no caller-identity branch anywhere in the function. `ConsensusWeb.UserLive.Confirmation` computes `@clears_password?` from the user alone — `is_nil(user.confirmed_at) and not is_nil(user.hashed_password)`, with no `@current_scope` input — so the warning now fires for a signed-in owner too, which is correct, because the outcome no longer depends on who is signed in.

**Why:** D-015's carve-out — "keep the password if the caller is already authenticated as that user" — did not close credential pre-stuffing. It renamed it. For an **unconfirmed** account, the only session that can exist is the one registration minted (D-004 signs the new account in immediately), and that session is derived from the very password under suspicion. So an attacker who registers the victim's address is, by construction, "already signed in as that user": the carve-out was reachable by exactly the person it was meant to exclude, and it reduced the attack from credential pre-stuffing to session fixation rather than eliminating it. "Already signed in" proves possession of a password; ownership of an unconfirmed account is proven only by reading the inbox.

Removing it also makes D-015's own headline claim true. D-015 asserted that "their credential stops working the moment the real owner clicks" — with the carve-out in place that held only when the attacker was not the one holding the session, i.e. not in the attack's own scenario. It is unconditionally true now.

This is also precisely what the "Mixing magic link and password registration" section of `mix help phx.gen.auth` prescribes, and it takes the function back to the arity the generator ships, which is one less divergence to maintain and to explain.

**Alternatives rejected:**
- Keeping the carve-out and documenting the residual session-fixation risk — the residual risk *is* the original attack with an extra step; documenting it is not mitigating it.
- Keeping arity 2 "in case a future caller needs the session" — a security branch nobody can currently justify is a branch someone will later restore by accident. The argument is the affordance.
- Confirming without discarding and forcing a password reset by email — no mail provider ships with this app (D-014), so the reset never arrives.

**Consequences:**
- A signed-in, unconfirmed user who clicks their own magic link now loses the password they just chose, where D-015 would have kept it. They land in sudo mode and set a new one from Settings; `UserLive.Confirmation` warns before the button is pressed and `UserSessionController` flashes after. That is the honest cost, and it falls on the one case that is indistinguishable from the attack.
- The reversal is guarded, not just documented: [test/consensus/accounts_test.exs](../test/consensus/accounts_test.exs) asserts `refute function_exported?(Accounts, :login_user_by_magic_link, 2)` alongside `assert function_exported?(..., 1)`. Reintroducing a session argument fails the suite.
- `ConsensusWeb.UserSessionController`'s magic-link clause is one of the four `UserAuth.disconnect_sessions/1` call sites in `lib/` (the others: `update_password/2` in that same controller, and both the demote and the delete branches of `ConsensusWeb.AdminLive.Users` — the delete one arrived with D-021). Here the link expires every other token for the account, so the sockets holding them must go. That is now pinned by "broadcasts a disconnect for every token the magic link expires" in [test/consensus_web/controllers/user_session_controller_test.exs](../test/consensus_web/controllers/user_session_controller_test.exs), which subscribes to `"users_sessions:" <> Base.url_encode64(token)` and asserts the `%Phoenix.Socket.Broadcast{event: "disconnect"}`. Deleting that line previously left the whole suite green.
- D-005 and D-015 are both amended in place above. Do not quote either entry's mechanism without reading this one.

---

## D-018 — `/health` proves the schema is current, and CI boots the image it builds

- **Date:** 2026-08-08
- **Status:** settled — replaces the `SELECT 1` described in D-016; **the CI half is extended by D-025**, which adds the `Host`-header re-check, the websocket-101 assertion and the boot-twice-on-one-volume step
- **Decision:** `ConsensusWeb.HealthController` runs **two** checks, in order:
  1. `Ecto.Migrator.migrations/3` must report no `:down` migration, or the endpoint answers `503 "migrations pending"`.
  2. `SELECT 1 FROM users LIMIT 1` — the table name resolved at compile time from `Consensus.Accounts.User.__schema__(:source)` — or the endpoint answers `503 "database unavailable"`. Both a `rescue` and a `catch :exit` clause map failures onto that second 503, because a dead or draining connection pool exits rather than raising.

  The `docker` job in `.github/workflows/ci.yml` then **runs** the image it builds: boot against a tmpfs `/data` owned by uid 65534, poll `/health` until `200 ok`, assert `Consensus.Accounts.count_admins() == 1` over `bin/consensus rpc`, then break the schema over `rpc` and assert `/health` turns 503. **D-025 added three more assertions to that job** — a second `/health` request under the deployed `Host`, a real LiveView websocket handshake asserting 101, and a whole second step that boots twice on one volume to migrate a populated database. Quote D-025 for the job's current shape.

**Why:** D-016 claimed the health check "queries the database, so a machine whose volume has gone away reports unhealthy instead of cheerfully serving 200". That was false as written. The query was `SELECT 1` — a constant expression SQLite answers without opening a single table — so a database file with **no application schema at all** passed it. A release whose boot-time `Ecto.Migrator` never ran would have answered 200 on `/health` while `GET /` returned 500, and the deploy would have gone green. Since this app has no `[deploy] release_command` (D-009), the boot-time migrator is the *only* thing that migrates production; a health check that cannot observe it is checking the wrong thing.

The migration half is passed `skip_table_creation: true` deliberately. The default `Ecto.Migrator.migrations/3` path calls `SchemaMigration.ensure_schema_migrations_table!/3`, i.e. a `CREATE TABLE IF NOT EXISTS` — a DDL **write**, and a probe polled every 30 seconds has no business taking SQLite's single write lock (D-013). Measured against the dev database: 578 µs/call with the option, 807 µs without; the `SELECT 1 FROM users LIMIT 1` costs 54 µs. `Ecto.Adapters.SQLite3.lock_for_migrations/3` is a no-op passthrough, so no migration lock is involved either way. If `schema_migrations` is missing entirely the query raises and we answer 503, which is the right answer.

The CI change is the other half of the same defect. Building an image proves it compiles, not that it boots, and `mix test` never starts a release — nothing else in this repo exercises the boot-time `{Ecto.Migrator, ...}` child, `Consensus.Seeds`, `Consensus.BootCheck` or the `config_env() == :prod` half of `config/runtime.exs`. A build-only job is what let this regression through, so the fix is not only a better endpoint but a job that would have caught the worse one.

**Alternatives rejected:**
- Keeping `SELECT 1` — the hole this entry exists to close.
- Checking only the migration state — it reads `schema_migrations`, which can be current while the volume underneath has gone; the table read is what notices that.
- A deeper check (counting rows, writing a heartbeat) — a write every 30s on a single-writer database, to learn nothing the read does not already establish.
- Letting `/health` stay 200 on a broken database so the machine stays in rotation — see the trade-off below; a green deploy over a broken app is the failure mode that does not get fixed.

**Consequences:**
- **A 503 pulls the single Fly machine out of Fly Proxy rotation, so a broken database becomes a hard outage rather than a site quietly serving 500s. That is intended, and it is a choice, not an oversight.** A failed deploy that is visible gets fixed; a green deploy over a broken app does not. The corollary follows from D-012: because there is exactly one machine, there is no healthy peer to shift traffic to — the 503 costs availability that was already gone.
- The controller now has a compile-time dependency on `Consensus.Accounts.User`. Renaming the `users` table without a migration turns `/health` red, which is the intended behaviour.
- `test/consensus_web/controllers/health_controller_test.exs` must stay `async: false`: proving the endpoint can fail means running DDL, and SQLite locks the whole database file for that. See AGENTS.md.
- The `docker` job costs roughly 30–60s more (about a minute in total after D-025). `fly-deploy.yml` calls `ci.yml` via `workflow_call`, so the deploy gate picks the smoke test up automatically: a release that fails to boot can no longer reach Fly.
- *(Resolved.)* This entry originally flagged two comments still describing the pre-D-018 world. `.github/workflows/ci.yml` no longer mentions `check_database_directory!/0` anywhere — that function does not exist; the preflight is `Consensus.BootCheck.run!/0`. `fly.toml`'s comment above `[[http_service.checks]]` now says `/health` "queries the database", which is accurate for the `SELECT 1 FROM users LIMIT 1` this entry installed. Nothing is outstanding.

---

## D-019 — Restoring a snapshot destroys and recreates the Machine

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** Recovery from a lost or corrupted volume is the procedure in **TODO.md §7, "Restoring from a snapshot" (steps R1–R8)**, and that procedure necessarily destroys the Machine and creates a new one. The step-by-step lives there and is deliberately not duplicated here.

  The operative fact it rests on: **a Machine's mount is bound to a volume ID fixed at Machine-creation time, not to the `[[mounts]] source` name `consensus_data`.** Therefore:
  - `fly volumes create --snapshot-id …` always produces a **new** volume with a new ID; there is no restore-in-place.
  - `fly deploy` cannot swap it — Fly's own documentation states that if a Machine has a mounted volume, `fly deploy` cannot be used to mount a different one.
  - `fly apps restart` cannot swap it either — it performs a rolling restart against running Machines, re-running the existing configuration, mount included.
  - Creating a fresh volume that happens to be *named* `consensus_data` does **not** reattach anything to the existing Machine.

  So the shape is fixed: snapshot → create the restored volume → destroy the Machine → destroy the old volume → `fly deploy --ha=false` to recreate the Machine against the restored volume.

**Why:** D-012 accepts single-machine/single-volume data-loss exposure explicitly, and CLAUDE.md invariant 4 cites that trade-off — but nothing recorded *how recovery actually works*, which is the entire justification for accepting the exposure. An accepted risk with an unwritten recovery path is an unaccepted risk. Writing it down also surfaced that the intuitive recovery ("restore the snapshot, restart the app") does not exist and never did: two of the three commands an operator would reach for first are no-ops for this purpose.

**Alternatives rejected:**
- Documenting the restore inline in `decisions.md` — this is a runbook with destructive checkpointed steps; it belongs where an operator is already looking, and duplicating it guarantees the two copies diverge.
- Leaving it to the `fly-io` skill alone — a skill is loaded by an agent, not read by a human at 2am.
- Automating restore behind a script — an irreversible, rarely-exercised procedure is exactly the wrong thing to hide behind one command.

**Consequences:**
- Recovery has a planned outage in it: the Machine is destroyed and recreated. Budget for that rather than discovering it mid-incident.
- The RPO remains "however old the daily snapshot is" (D-012, `snapshot_retention = 30`).
- **The procedure is verified only against `fly --help` and Fly's published guides; it has never been executed against a live app.** Treat the first real restore as a test of the runbook as well as of the backup.
- No document may state that `fly apps restart` or a `fly deploy` re-points an existing Machine at a new volume, or that creating a volume named `consensus_data` reattaches it. Both are false, and both were the substance of the bug this entry fixes.

---

## D-020 — The default home-page message is a list of lines, not a heredoc

- **Date:** 2026-08-08
- **Status:** superseded by D-027 — the admin-editable home page no longer exists.
- **History, not instruction:** everything below describes a feature that was deleted. The transferable part is the *reason*: whitespace inside a string that renders under `whitespace-pre-wrap` is layout, `mix format` never reflows string contents, and the guard for that has to be behavioural. Keep that rule for any future pre-wrapped text; the module, the assign and the tests named below are gone.
- **Decision:** The public home page renders the admin message inside a `whitespace-pre-wrap` paragraph, so **the message string's line structure is its rendered layout**. `Consensus.Content`'s `@default_message_lines` is therefore a list of strings joined with `"\n"` — one list element per rendered line — rather than a heredoc, so a line break is a data decision rather than a formatting accident. The current value, exactly:

```
Welcome to Consensus.

An admin can edit this message from the admin area: sign in, then open Admin → Home page.
Whatever you type there shows up here for everyone, live.
```

  The `<p id="home-message">` element in the HEEx template carries `phx-no-format` for the same reason, and its opening `>` sits immediately before `{@home_page.message}` with `</p>` immediately after — with `pre-wrap`, a newline or indentation between the tags is itself rendered text.

**Why:** `mix format` never reflows string contents, so it cannot catch a source wrap leaking into the page — the failure is invisible to every check this repo runs. And it had already shipped twice: round 2 fixed the template, and the string it renders was still wrapped to the ~90-column source margin. Measured in Chrome at viewport 1280, the previous heredoc forced a break 63.8 px short of the 718 px paragraph width; at viewport 411 it put "page," alone on a row. This is the first prose a fresh install shows anyone, so a staircased paragraph is the app's first impression.

A list makes the failure visible at the point of editing: a stray indent inside a heredoc reads as ordinary whitespace, whereas inside quotes it sits plainly in the string.

**Alternatives rejected:**
- A heredoc with a comment saying "do not reflow" — the previous state, and it did not hold.
- Dropping `whitespace-pre-wrap` so line breaks in the message collapse — that would break the admin-authored message, whose paragraphing is the whole point of the editor.
- Relying on review to catch it — it survived one round of review already.

**Consequences:**
- Guarded behaviourally, not by formatting: the `"default_message/0"` describe in [test/consensus/content_test.exs](../test/consensus/content_test.exs) asserts that no line carries leading or trailing whitespace, that no non-empty line ends anywhere but `.`, `!` or `?`, that no line carries a second sentence, and that the message neither opens nor closes with a blank line. **A colon was accepted here once, and accepting it was the hole rather than a nicety:** the default message contains exactly one colon, mid-line, and it is the single most tempting place to wrap the source. Splitting there left one fragment ending in `:` and one ending in `.` — both accepted, both wrong, the page grew a line break nobody asked for, and the suite stayed green. Only a sentence-ending mark ends a line now. [test/consensus_web/live/home_live_test.exs](../test/consensus_web/live/home_live_test.exs) extracts the `<p id="home-message">` body and compares it byte for byte against the HTML-escaped stored message, so reflowing that tag fails a test instead of passing a cosmetic check.
- **The fix is not retroactive.** `Consensus.Content.ensure_home_page!/0` inserts the default once and never rewrites it, so every database seeded before this change — including the current local `consensus_dev.db` — keeps the old wrapped text until an admin edits it at `/admin/home-page`. This affects seeding only.
- Any future user-visible string rendered into a whitespace-significant element inherits this rule. Wrapping such a string to a source margin is a defect, and no tool in this repo will tell you.

---

## D-021 — Granting or destroying authority requires sudo mode, returns the affected tokens, and is audited

- **Date:** 2026-08-08
- **Status:** settled — extends D-006 and the `delete_user/2` half of D-015. The UX cost below was
  put to the repo owner explicitly and **accepted** on 2026-08-08: *"if you come back to an open
  /admin/users tab an hour later, the buttons will be disabled and clicking bounces you to log in
  again — that is acceptable."* Recorded because this is a security/convenience trade, not a
  correctness one, so a future reader weighing "is the friction worth it?" is weighing a question
  that has already been answered rather than reopening it.
- **Decision:** The two `Consensus.Accounts` functions that grant or destroy authority — `set_admin/3` and `delete_user/2` — now share one shape, enforced in the context and nowhere else:

  1. **Sudo mode.** Inside the same `Repo.transact/1` `with` chain that re-reads the actor's role, a private `ensure_actor_in_sudo_mode/1` calls `Accounts.sudo_mode?/1` on the re-read actor and returns `{:error, :sudo_required}` when the last authentication is older than `@sudo_mode_minutes`, which is **20**. Note this is a *different* window from `/users/settings`, which passes `-10` explicitly in `ConsensusWeb.UserAuth.on_mount(:require_sudo_mode, ...)`. Both are deliberate and both are live; do not "unify" them without deciding which one you mean.
  2. **`{:ok, {user, tokens_to_disconnect}}` from both.** `set_admin/3` already returned it (D-016). `delete_user/2` now does too, collecting the target's `"session"` tokens *before* `Repo.delete/1`, because `ON DELETE CASCADE` removes them with the row. `ConsensusWeb.AdminLive.Users` passes them to `ConsensusWeb.UserAuth.disconnect_sessions/1` on **both** branches.
  3. **An audit line, on success and on refusal.** A private `audit/4` wraps the result: `Logger.info("[audit] <action> actor_id=… actor=… target_id=… target=…")` on `{:ok, _}`, `Logger.warning("[audit] <action> REFUSED <reason> …")` on `{:error, reason}`, where `<action>` is `grant_admin`, `revoke_admin` or `delete_user`. It returns its input unchanged.

  `ConsensusWeb.AdminLive.Users` mirrors the gate in the UI — a private `require_sudo/2` that flashes and `push_navigate`s to `/users/log-in`, a `<div :if={!@sudo?} id="sudo-notice">` banner, and `disabled={!@sudo?}` on Promote, Demote and Delete — but **that is a courtesy, not the enforcement.** A `disabled` attribute is a client-side hint; the `phx-click` event can be pushed regardless. `Consensus.Accounts` is the only thing that refuses.

**Why, one by one:**

*Sudo mode.* Before this, a session token was enough to promote someone to administrator for as long as the token lived. A borrowed laptop, a stolen cookie or an unattended tab was therefore a permanent privilege escalation, and the app already had a stronger standard for a *lesser* action: changing your own email requires re-authentication. Requiring at most a 20-minute-old authentication to hand out or destroy an account brings the two into the right order. Twenty rather than ten because these are things an operator does in a deliberate sitting — promote three people, delete two dead accounts — and a ten-minute window mid-task means logging in again to finish the list.

*Returning the tokens from `delete_user/2`.* The previous state was defensible only by an accident: the deleted person's mounted LiveView kept running on a scope with no account behind it, and that was safe *because* `delete_user/2` refuses to delete an administrator, so the stale socket was never privileged. That is a property of a neighbouring guard, not of this code, and it would have broken silently the first time someone made deletion reachable for a privileged user. Now both writes disconnect and the reasoning is local.

*The audit line.* One machine, no external audit sink, no undo, and the two most consequential writes in the app. Without a log there is no answer to "who promoted this account?" The refusals matter as much as the successes: a run of `REFUSED :unauthorized` is what acting from a revoked session looks like, and `REFUSED :sudo_required` distinguishes an operator who let the window lapse from an attacker with a stolen cookie. Ids lead because usernames are mutable; nothing derived from a password is logged.

**Alternatives rejected:**
- *Enforcing sudo only in the LiveView (`on_mount :require_sudo_mode` on the admin live_session).* It would block the mount but not a pushed event on an already-mounted socket, and it would put the rule where LiveDashboard — which has no context to re-read (D-011) — could not benefit from it. Worse, it would make the `disabled` attributes look like the enforcement.
- *Removing the UI disabling because the server enforces.* An operator who clicks Promote and gets bounced to the log-in form mid-task learns the rule the expensive way. The notice explains it before the click.
- *Auditing successes only.* Refusals are the security-interesting half.
- *A `user_audit_events` table.* A durable record is a real want, but it is a schema, a retention policy and a migration to answer a question no one has asked yet — and it belongs beside the voting-engine schema decisions, not ahead of them. The log line is the floor, not the ceiling.
- *Reusing the 10-minute settings window.* See above: the two actions have different rhythms.

**Consequences:**
- **An admin returning to a tab they left open must log in again to promote or delete.** The window
  is 20 minutes and the `:sudo?` assign is computed once, at mount, so a long-open `/admin/users`
  renders enabled buttons that will bounce. Accepted by the owner (see Status). If it ever needs
  softening, the honest fix is to refresh the assign — not to widen the window and not to drop the
  context check.
- **A LiveView test that promotes or deletes must put the actor in sudo mode first**, i.e. mint the scope with a recent `authenticated_at`. This is the single most likely thing to break when adding a test to `test/consensus_web/live/admin_live/users_test.exs`, and the failure surfaces as an unexpected redirect to `/users/log-in`, not as an assertion about roles.
- Removing the sudo gate from `Consensus.Accounts` while leaving `#sudo-notice` and the `disabled` attributes in place would leave the page *looking* correct and the app unprotected. Treat the context check as the invariant and the UI as decoration.
- `[audit]` lines are `:info` on success, so `config :logger, level: :info` in `config/prod.exs` keeps them. Raising the production log level to `:warning` would silence every successful promotion while keeping the refusals — a half-log worse than none. Do not.
- Both functions also `rescue Exqlite.Error` into `{:error, {:database_busy, _}}`: SQLite raises rather than returning a tuple when a write cannot take the lock (D-013), and that is not worth crashing a LiveView over.
- Covered by [test/consensus/accounts_test.exs](../test/consensus/accounts_test.exs) and [test/consensus_web/live/admin_live/users_test.exs](../test/consensus_web/live/admin_live/users_test.exs).

---

## D-022 — The boot preflight probes the whole WAL set, and every `Release` entry point runs it

- **Date:** 2026-08-08
- **Status:** settled — amends change 1 of D-016
- **Decision:** `Consensus.BootCheck`'s file probe covers **`DATABASE_PATH`, `<path>-wal` and `<path>-shm`**, filtered through `File.exists?/1` so only the members that are actually present are opened for `:append`. The failure message leads with a `refused       : <path>` line naming the member that said no, then `DATABASE_PATH`, the directory, and every WAL-set member with its uid/gid/mode.

  And **all three `Consensus.Release` entry points preflight**: `migrate/0`, `seed/0` and — new here — `rollback/2`.

**Why the WAL set.** `config/runtime.exs` pins `journal_mode: :wal` (D-013). SQLite must therefore open and write two sidecar files beside the database, and it cannot start without write access to all three. Their ownership can differ from the database's. A `DATABASE_PATH`-only probe walks straight past a root-owned `-wal` on its way to `unable to open database file` and a `DBConnection.ConnectionError` about pool size — which is the same misdirection D-016 existed to eliminate, reintroduced one file over.

**Record this before somebody "simplifies" it back, because the obvious mental model is wrong.** Running `sqlite3` as root over `fly ssh console` does **not** strand root-owned sidecars: SQLite `fchown`s a journal it creates to match the database file's owner, precisely so a root maintenance session cannot lock the daemon out. Verified. So "an operator poked at it as root" is *not* how you get here, and someone reasoning from that will conclude the check is unreachable and delete it. The reachable causes are: a root `cp` / `tar` / snapshot restore that preserves its own ownership (D-019's procedure moves files around as root), a non-SQLite root process writing one of those paths, or root having created the database in the first place. The comment above `ensure_database_writable/1` says all of this in the source; keep it there too.

**Why `rollback/2` now preflights.** D-016 exempted it, and the exemption had no stated reason beyond symmetry with "rollback is not part of the deploy path". But `rollback/2` is the command an operator types *at a machine that is already broken* — it is strictly more likely to meet an unwritable volume than `migrate/0` is. Running it against a root-owned `/data` produced exactly the connection-pool red herring the preflight exists to prevent. The cost of the check is three `File.open/2` calls.

**Alternatives rejected:**
- *Probing only `DATABASE_PATH`.* The hole this entry closes.
- *Probing all three unconditionally, without the `File.exists?/1` filter.* Opening a non-existent `-wal` for `:append` would create it — the preflight would be writing files into the volume as a side effect of checking it, and on a first boot it would leave two empty sidecars that SQLite then has to reconcile.
- *Re-stating `DATABASE_PATH` in the error instead of the refused path.* That is what sends the operator to inspect a file that is perfectly healthy.
- *Turning off WAL to avoid the problem.* WAL is why concurrent readers do not block the single writer (D-013); the trade is not close.

**Consequences:**
- The failure message has a new leading line. Grep production logs for `refused       :` as well as `Cannot write the SQLite database` and `is not a mount point`.
- The `chown -R 65534:0 /data` remedy is unchanged and still correct — it is recursive, so it fixes the sidecars along with the database. That is why the message says "Fix the lot".
- Pinned by [test/consensus/boot_check_test.exs](../test/consensus/boot_check_test.exs), which builds a root-owned sidecar beside a healthy database and asserts the `refused` line names the sidecar, and by the `"the boot preflight"` describe in [test/consensus/release_test.exs](../test/consensus/release_test.exs), which pins all three entry points.
- No document may say `rollback/2` skips the preflight. D-016 has been amended in place.

---

## D-023 — `PHX_HOST` must equal `<app>.fly.dev`, and `fly.toml` is machine-checked against itself

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `fly.toml`'s `[env] PHX_HOST` must be the hostname the browser actually uses to reach the app — for a stock Fly deploy, `<app>.fly.dev`, where `<app>` is the `app` key in the same file. [test/consensus/deploy_config_test.exs](../test/consensus/deploy_config_test.exs) asserts it, along with three other same-file agreements: `PORT` equals `[http_service] internal_port`, `DATABASE_PATH` sits inside `[[mounts]] destination`, and `PHX_HOST` is a **single-quoted** scalar on its own line (the shape `ci.yml`'s `sed` expression depends on). The test reads `fly.toml` as text, needs no database, is `async: true`, and fails on a pull request.

**Why:** this is the deploy failure that reports success. `config/runtime.exs` takes the endpoint's `:url` host from `PHX_HOST`; `check_origin` defaults to `true` in production and validates the browser's `Origin` header against that host. Every user-facing page in this app is a LiveView. So a `PHX_HOST` that is not the real hostname 403s **every** socket upgrade — total loss of interactivity — while:

- `GET /` still answers **200**, because LiveView static-renders on the dead-render pass, before any socket exists;
- `GET /health` still answers **200**, because it is origin-free, session-free and outside the `:browser` pipeline;
- `[[http_service.checks]]` polls exactly `/health`, so **Fly reports the machine healthy and the deploy goes green.**

`fly.toml`'s own header instructs the operator to change `app` and then "make PHX_HOST match the hostname Fly gives you" — two stanzas, one invariant, and until now nothing checking it. The `docker` job's websocket assertion (D-025) catches an endpoint that rejects its *own* declared hostname, but it reads `PHX_HOST` out of `fly.toml` and feeds the container that same value, so `app` and `PHX_HOST` drifting apart is invisible to it by construction. Hence a unit test.

**Alternatives rejected:**
- *Relying on the CI websocket assertion alone.* Blind to this exact drift, for the reason above.
- *Setting `check_origin: false` in production.* It is the defence against a hostile page opening a socket to this app with the user's cookies; turning it off to paper over a config error trades a CSRF-class protection for a `sed` expression.
- *Deriving `PHX_HOST` from `FLY_APP_NAME` at runtime.* Tempting, and it would make the mismatch unrepresentable — but it silently breaks the moment the app is served from a custom domain, and it moves a value an operator can read in `fly.toml` into logic they have to infer. The test keeps the value declarative and the invariant checked.
- *Asserting it in the `docker` job instead.* Same coverage at ten times the latency, after a full image build.

**Consequences:**
- **Renaming the Fly app is now a two-line edit that fails loudly if you do half of it.** That is the entire point.
- **Moving to a custom domain is a real decision, not a test failure to delete.** Edit the first test to expect the domain, and record the move here. The test's own failure message says so.
- Reformatting `fly.toml` to double-quoted TOML is valid and would still deploy, but would break `ci.yml`'s extraction. The fourth test catches that in seconds rather than in the slowest job in CI.
- The test asserts against `fly.toml`'s literal text, so it cannot see `PHX_HOST` set another way — `fly secrets set PHX_HOST=…` would override the `[env]` value invisibly. Do not set it that way; it is not a secret.

---

## D-024 — The navbar's user group is `min-w-0`, not `flex-none`

- **Date:** 2026-08-08
- **Status:** superseded by D-028 — there is no navbar.
- **History, not instruction:** `#user-nav` and its `min-w-0` were deleted with the global header. The transferable part is the *reason*: `flex-none` is `flex-shrink: 0`, which makes a sibling `flex-wrap` dead code. That trap is live anywhere we lay a row out with flex; the element and the test named below are gone.
- **Decision:** In [lib/consensus_web/components/layouts.ex](../lib/consensus_web/components/layouts.ex), the navbar's right-hand group is `<div id="user-nav" class="min-w-0">`, replacing the generator's `flex-none`. The header itself is `flex-wrap gap-y-1`, and the `<ul>` inside is `flex flex-wrap items-center justify-end gap-1`. The `id` exists so a test can assert on the element.

**Why:** `flex-none` is shorthand for `flex: none`, i.e. `flex: 0 0 auto` — **`flex-shrink: 0`**. A flex item that cannot shrink cannot be squeezed below its content width, so on a narrow viewport the group simply overflowed the header: the right-hand end of it, including the theme toggle's dark segment, went off-screen. The `flex-wrap` already on the header and on the `<ul>` was dead code — wrapping only happens when the browser is allowed to run out of room, and `flex-shrink: 0` guarantees it never appears to. `min-w-0` removes the `min-width: auto` floor that flex items get by default, which is what actually lets the group narrow and the wrap fire.

This is worth an entry rather than a commit message because the two classes look interchangeable and the generator's choice looks authoritative. Reverting to `flex-none` would restore a bug that only appears below a viewport width nobody tests by hand, and `mix format` and the compiler are both blind to it.

**Alternatives rejected:**
- *Keeping `flex-none` and hiding items below a breakpoint.* Hides the log-out control on exactly the devices where it is hardest to find another route to it.
- *`overflow-hidden` on the header.* Clips the problem rather than resolving it, and clips it silently.
- *`flex-shrink` on the `<ul>` instead of `min-w-0` on the wrapper.* Does not remove the `min-width: auto` floor, so it under-shrinks; `min-w-0` is the idiomatic fix for this exact failure.

**Consequences:**
- `id="user-nav"` is asserted, so it is API. Renaming it breaks a test on purpose.
- Any new navbar item inherits the wrap rather than pushing the group off-screen. Check a narrow viewport when adding one.

---

## D-025 — CI boots the image under the deployed hostname, upgrades a real websocket, and migrates a populated database

- **Date:** 2026-08-08
- **Status:** settled — extends the CI half of D-018
- **Decision:** The `docker` job in `.github/workflows/ci.yml` builds the image (tag `consensus:ci`, `load: true`) and then runs **two** boot steps.

  **Step one — boot and smoke test**, one container on a tmpfs `/data` owned by uid 65534, booted with `PHX_HOST` extracted from `fly.toml` rather than hardcoded. Five assertions, in order:
  1. `/health` answers `200 ok`, polled at `127.0.0.1` for up to 60s;
  2. `/health` answers `200` again under `Host: $PHX_HOST`;
  3. a real websocket handshake against `/live/websocket?vsn=2.0.0` — `Host` and `Origin` set to `$PHX_HOST`, plus `x-forwarded-proto: https` so `force_ssl` does not 301 it — returns **101**;
  4. `Consensus.Accounts.count_admins() == 1` over `bin/consensus rpc`;
  5. the schema is broken over `rpc` and `/health` must then answer **503**.

  **Step two — boot twice on one volume.** On a real named Docker volume: boot, rename the seeded admin over `rpc`, stop and remove the container, roll the newest migration down via `bin/consensus eval`, then boot a second container on the same volume and assert `/health` 200, a `== Migrated` line in the logs, exactly one admin, and that the admin still carries its **new** name.

**Why assertion 2.** `config/prod.exs` excludes `/health` from `force_ssl` two independent ways: `paths: ["/health"]` and `hosts: ["localhost", "127.0.0.1"]`. The polling loop in assertion 1 goes to `127.0.0.1`, so it is satisfied by the `hosts:` exclusion alone and would stay green with `paths:` deleted entirely. Fly's checker sends the machine's own hostname, not `127.0.0.1`. Only a request carrying the deployed hostname distinguishes the two, and `paths:` is the one production depends on.

**Why assertion 3.** Same failure mode as D-023, observed from the other side: `check_origin` defaults to true in prod and validates `Origin` against the endpoint's `:url` host. Because every page here is a LiveView, a rejected handshake is a completely dead app — and nothing else notices, since `GET /` static-renders 200 and `/health` is origin-free. Verified to discriminate against the release image: 101 when `Origin` matches `PHX_HOST`, 403 when it does not. Two mechanical details are load-bearing: `x-forwarded-proto: https` (without it `force_ssl` 301s the upgrade and the assertion measures the wrong thing), and `|| true` on the curl (a *successful* upgrade holds the connection open, so curl exits 28 once `--max-time` elapses — having already written the status — and `set -e` would otherwise abort the step on the passing path).

**Why step two.** Every other boot in this repo starts from an empty database: the smoke test uses a fresh tmpfs, and `mix test` starts from an empty file. Nothing had ever migrated a database that already had rows in it — which is what every deploy after the first one does, and this app has no `[deploy] release_command` (D-009), so the boot-time migrator is the only thing that ever will. Renaming the admin between the boots does double duty: it proves the existing row survived, and it re-proves that `Consensus.Seeds` gates on "are there zero admins?" rather than on the bootstrap username, so a renamed account is not mistaken for a first boot and quietly recreated with the documented default password (D-010).

**Alternatives rejected:**
- *Hardcoding `PHX_HOST=localhost` in the smoke step.* What the step used to do. It is on the `hosts:` `force_ssl` exclusion, so it bypasses the check being tested, and it makes `check_origin` trivially satisfiable. Convenient and worthless.
- *Asserting `GET /` returns 200 as a proxy for "the app works".* It returns 200 in precisely the broken case — LiveView's dead render does not need a socket.
- *Testing the socket with a real LiveView client instead of curl.* More machinery in a shell step to observe the same status code.
- *Simulating an upgrade in `mix test` instead.* `Phoenix.LiveViewTest` does not exercise `check_origin` or the release's runtime configuration; the whole point is that this is the `:prod` config path.

**Consequences:**
- `fly.toml` is now an input to CI. The `sed` expression depends on `PHX_HOST` being a single-quoted scalar; D-023's fourth test guards that shape so the failure lands on the pull request rather than after an image build.
- The job runs three containers and one named Docker volume, all torn down in `if: always()` steps that also dump `docker logs` for each. Adding a container means adding it to both lists.
- **Do not reduce any of this to a plain `docker build`.** A build-only job is what let the `/health` regression deploy green once already (D-018). No document may describe CI's docker half as "a `docker build`".
- What it still does not cover: a migration that has never run anywhere. The pending migration in step two already succeeded on the first boot, so a `down` that is not a faithful inverse of its `up`, or a SQLite `ALTER TABLE` that only fails against real rows, would still slip through.
- The complete local reproduction lives in `.claude/skills/elixir/SKILL.md`, "Reproducing CI locally, completely".

---

## D-026 — The home-page textarea has no `maxlength`; a grapheme counter replaces it

- **Date:** 2026-08-08
- **Status:** superseded by D-027 for its subject; **its rule still binds.**
- **Still in force:** the home-page textarea is gone, but the rule it established is not. Every free-text field in this app — the option description on design frame `02b` is the live example — has no `maxlength`, a visible counter in the server's own unit, and the real limit in the changeset. Read the reasoning below as current; read `Consensus.Content.HomePage` and `admin_live/home_page.ex` in it as deleted files.
- **Decision:** The `<.input type="textarea">` in [lib/consensus_web/live/admin_live/home_page.ex](../lib/consensus_web/live/admin_live/home_page.ex) deliberately carries **no `maxlength` attribute**. In its place a live `<p id="message-counter">` renders `{@message_length} / {HomePage.max_message_length()} characters` and turns `text-error` when the count is over, with `aria-describedby="message-counter"` on the field. `@message_length` is computed with `String.length/1` on the changeset's already-cast (and therefore trimmed) value, so it counts what the server counts. `Consensus.Content.HomePage` remains the enforcement: `validate_length(:message, min: 1, max: 2_000)` (graphemes) **and** `validate_length(:message, max: 8_000, count: :bytes)`.

**Why:** `maxlength` and the changeset do not measure the same thing. A browser enforces `maxlength` in **UTF-16 code units**; `validate_length/3` counts **graphemes** by default. One emoji outside the BMP is 1 grapheme and 2 code units, and a family emoji built from a ZWJ sequence is 1 grapheme and many more. So the two disagree on any non-ASCII message — and the browser's way of disagreeing is the worst available: it **silently truncates a paste**, keeping the head, dropping the tail, and saying nothing. The admin gets a message that looks saved and is not what they wrote.

A server-side error the admin can read beats a client-side limit they cannot see. The counter gives the same forewarning `maxlength` was meant to give, in the same units the validation uses, without the ability to destroy input.

The byte cap exists for a different reason and is not redundant: 2 000 graphemes of emoji is roughly 8 KB of TEXT, so the grapheme limit alone does not bound what reaches the database. Two limits, two units, both server-side.

**Alternatives rejected:**
- *Keeping `maxlength={HomePage.max_message_length()}`.* The silent-truncation bug, dressed as a convenience.
- *A `maxlength` set to the byte cap "to be safe".* Still the wrong unit, still truncating, and now 8 000 code units of a limit the changeset expresses as 2 000 graphemes — the numbers on screen would contradict the error message.
- *Counting with `byte_size/1` in the UI.* Would match the byte cap and not the grapheme cap; the grapheme cap is the one an admin hits first, and characters are what they think in.
- *No counter at all.* Then the only feedback is a failed save after writing a long message, which is the worst point to learn about a limit.

**Consequences:**
- The counter must keep counting the way the server counts. If `HomePage`'s primary limit ever changes unit, `message_length/1` changes with it — they are one decision in two files.
- Over-limit input reaches the server and is rejected there. That is intended: the admin sees a readable error rather than a truncated message.
- Any future free-text admin field inherits this: no `maxlength`, a visible counter in the server's unit, validation in the changeset.

---

## D-027 — `/` is the product; the admin-editable home page is deleted

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `Consensus.Content`, `Consensus.Content.HomePage`, `ConsensusWeb.AdminLive.HomePage`, the `/admin/home-page` route and the `home_page` table are all removed, and `priv/repo/migrations/20260808183755_drop_home_page.exs` drops the table with a `down/0` that recreates its schema (not its contents — there is no copy to restore). `/` now renders one of two things: design frame `00a`, the signed-out splash, or design frame `00`, the signed-in list of activity groups. `ConsensusWeb.HomeLive` still owns the route.

**Why:** the home page existed because there was no product behind `/` yet — a single admin-authored paragraph was a placeholder standing where the app would go. The app has now gone there. A paragraph of prose has nowhere to render on a screen whose entire content is the organizer's own sessions, and keeping the table would leave a foreign key into `users` constraining `Accounts.delete_user/2` in exchange for nothing.

Deleting rather than orphaning is the point. An unused context with passing tests reads as a live feature to the next person, and CLAUDE.md is explicit that a confidently wrong document is worse than a silent one; the same is true of code.

**Alternatives rejected:**
- *Keep the table, drop the UI.* An unreachable column with a live FK, and a migration debt that gets harder the longer it waits.
- *Keep the message as a banner above the group list.* Invents a product decision — an admin broadcast channel — that the PRD does not ask for, on the one screen that must stay uncluttered.
- *Leave the code and route it away.* Dead code that still compiles, still runs in CI, and still looks authoritative.

**Consequences:**
- D-020 and the subject of D-026 are superseded; both are annotated in place. D-026's *rule* survives and now applies to the option description on `02b`.
- `Consensus.Seeds.run!/0` returns `{:ok, %{admin: admin_or_nil}}` — the `:home_page` key is gone. Its three callers and `test/consensus/seeds_test.exs` are updated.
- `test/consensus/release_test.exs` now asserts `home_page` is **absent** after `migrate/0` — which is what proves the whole migration chain ran rather than a prefix — and **present** after rolling back exactly the newest migration, which is the only test of that `down/0`.
- Invariant 11 in CLAUDE.md (the whitespace-significant home-page message) no longer describes any code and is rewritten.

---

## D-028 — daisyUI is removed; the design tokens are the whole system

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `assets/css/app.css` no longer loads the daisyUI plugin or either generated theme. In its place is a Tailwind v4 `@theme` block holding the palette, the two typefaces and the hard offset shadows from [docs/design/DESIGN-SPEC.md](design/DESIGN-SPEC.md), plus a handful of `@layer components` helpers (`.press-2/3/4`, `.eyebrow`, `.stripes-*`). `ConsensusWeb.CoreComponents` is restyled onto those tokens with its public API unchanged, and `ConsensusWeb.Sticker` adds the design-specific primitives. Dark mode and the theme toggle are gone — the design is one committed light theme.

**Why:** the imported design is a "sticker" system: a 2px ink outline, a hard *unblurred* offset shadow, and a 1px press on every interactive surface. daisyUI has its own opinions about all three (`--border: 1.5px`, `--depth`, `--radius-*`, blurred elevation), expressed as theme variables that its component classes read. Every screen became a fight between two systems, and the losing move — overriding `btn` and `input` per-call-site — leaves the app looking almost right everywhere and exactly right nowhere.

Removing it also removed the theme toggle, and that is a feature not a loss: a dark variant of a design built on ink outlines and mint fills is a second design, and nobody has drawn it.

**Alternatives rejected:**
- *Keep daisyUI and author a Consensus theme.* Its theme variables cannot express "shadow with zero blur that shrinks by 1px on hover", which is the single most characteristic thing in the design.
- *Keep daisyUI for the admin and auth screens only.* Two systems in one app, and the auth screens are the first thing a new organizer sees.
- *Keep the dark theme with guessed values.* Guessed dark colours on a palette this saturated is how an app ends up with unreadable mint-on-mint.

**Consequences:**
- Any `btn`, `input`, `card`, `alert`, `menu`, `badge`, `tabs`, `toggle`, `fieldset` or `loading` class left in HEEx is now dead and renders unstyled. Grep before adding one.
- D-024 is superseded: there is no navbar to shrink. Its underlying trap — `flex-none` making a sibling `flex-wrap` dead code — is still real and is preserved in that entry.
- The two typefaces load from Google Fonts in `root.html.heex`. That is a third-party request on every page load, accepted for now; self-hosting them is a one-file change when it matters.

---

## D-029 — An activity group is a draft first, and completion is lazy

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `Consensus.Activities.Group` has a four-state `status`: `:draft → :voting → :completed | :cancelled`. Step 1 of the wizard **creates the row immediately** as a `:draft`; steps 2 and 3 edit it in place; `publish_group/2` at "Get the share link" moves it to `:voting`. `cancel_group/2` is an organizer action available on an active group. Automatic completion is `maybe_complete_group/1`, called **lazily from the read paths** (`list_groups/1`, `get_group!/2`, `get_group_by_slug/1`) — there is no scheduler, no GenServer and no periodic job.

**Why, on the draft:** the requirement is "never make me re-enter anything". A wizard that accumulates state in the LiveView and writes once at the end loses everything to a closed tab, a dropped websocket or a phone that sleeps — which is most of the organizer's session, since the persona is someone doing this in a group chat on a phone. Writing on step 1 makes every later step an `UPDATE` and makes resuming free.

**Why, on lazy completion:** a group whose deadline passes while nobody is looking is completed the next time anyone looks. That is indistinguishable from a scheduler for every observer, and it cannot drift: there is no timer to miss, nothing to reconcile after a deploy, and a single-machine deployment (D-013) that restarts on every deploy would lose in-flight timers anyway. The "everyone has voted" half of completion is a documented `TODO` against `expected_voter_count`; it needs the voting side, which is not built.

**Alternatives rejected:**
- *Build the group only on submit.* Loses the draft on any interruption, which is the failure mode we were told to prevent.
- *A `Quantum`/`GenServer` deadline sweeper.* A dependency and a supervised process to make a state transition nobody can observe before their next read.
- *A boolean `published` instead of a status enum.* Cannot express cancelled, which the user explicitly asked for.

**Consequences:**
- Drafts appear on the home screen under `ACTIVE` with a `DRAFT` pill. That is deliberate — a half-finished session the organizer forgot about is exactly what the home list should surface.
- `activities.position` contiguity is an application invariant maintained by `delete_activity/2` and `reorder_activities/3`, **not** a database constraint: SQLite checks immediately with no deferred mode, so a unique index on `(group_id, position)` would collide mid-renumber inside the transaction.
- **Amended by D-037:** `:draft → :voting` freezes the activity pool as well as ending the wizard. All four pool writes — `add_activity/3`, `update_activity/3`, `delete_activity/2`, `reorder_activities/3` — refuse with `{:error, :pool_locked}` outside `:draft`, because `votes.activity_id` cascades and editing a pool that has been voted on destroys ballots. So the two functions named above maintain contiguity only while the group is a draft; afterwards there is nothing to renumber.
- Reading is no longer side-effect-free. `list_*` and `get_*` may write a status transition. Any future read path that must not write has to skip `maybe_complete_group/1` explicitly.

---

## D-030 — A pasted link is fetched server-side, guarded, cached, and never downloaded

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** Pasting a URL into "add an option" calls `Consensus.LinkPreview.fetch/1`, which returns OpenGraph title/description/image (falling back to `<title>` and `<meta name=description>`). It refuses non-`http(s)` URLs, refuses private, loopback and link-local hosts, re-checks that guard on each of at most 3 redirects, times out at 5s, caps the body at 512 KB, and never raises — every failure is an `{:error, atom}`. Results **and errors** are cached in ETS (6 hours and 5 minutes respectively). The image is stored as a **URL only**; nothing is downloaded, proxied or hosted. Callers invoke it from `start_async`, never inline in `handle_event`.

**Why:** a pasted URL is untrusted input that we then ask our own server to request. Without the host guard, `http://169.254.169.254/…` turns the paste field into a cloud-metadata reader and `http://127.0.0.1:4000/admin/...` turns it into an authenticated-adjacent request forger. That guard has to run per redirect hop, because a public host that 302s to `10.0.0.1` defeats a check done only on the input.

The cache is not an optimisation, it is the working agreement in CLAUDE.md: external calls get a caching layer in the same commit that introduces them. Caching errors matters as much as caching successes — a dead link pasted five times must not mean five outbound requests.

Storing only the URL keeps us out of image hosting, storage sizing, content moderation of uploaded bytes, and the volume-capacity question entirely. The cost is that a third-party image can 404 later; `photo_frame/1` degrades to the striped placeholder when it does.

**Alternatives rejected:**
- *Fetch in the browser.* CORS makes it fail on most sites, and it moves the request to a client we cannot rate-limit.
- *Fetch inline in `handle_event`.* A slow third-party server would freeze the LiveView process and, with it, the user's whole page.
- *An allowlist of domains instead of a denylist of addresses.* Wrong shape: organizers paste from anywhere, and the risk is the address family, not the brand.
- *`LazyHTML` for parsing.* It is a `:test`-only dependency. Regex parsing of meta tags is deliberate and documented in the fetcher.

**Consequences:**
- DNS resolution failure for a symbolic host is **not** treated as `:blocked_host` — an unresolvable host surfaces as `:fetch_failed` instead. The guard does not assert a verdict it cannot back up.
- `Consensus.LinkPreview.Cache` is a supervision child between `Consensus.Repo` and `ConsensusWeb.Endpoint`, and `test/consensus/application_test.exs` asserts that position, the way invariant 2 already does for the migrator and the seeds.
- The fetcher is injected via `config :consensus, Consensus.LinkPreview, fetcher:` so tests never touch the network.

---

## D-031 — Deadline chips are computed from a browser-supplied UTC offset

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** The three chips on design frame `01` — `Tonight 5pm`, `Tomorrow 5pm`, `Thu noon` — are computed by `Consensus.Deadlines`, not stored. The browser sends `tz_offset` (minutes east of UTC) in the LiveView connect params from `assets/js/app.js`; `Consensus.Deadlines` shifts UTC by that offset to get local wall time, snaps to the target hour, and shifts back. A dead render with no connect params falls back to UTC. The design's dashed `Custom…` chip renders **disabled**.

**Why:** named time zones need a tz database, and `tzdata` is not a dependency — adding one for three chips means a runtime data download, a periodic updater, and a new failure mode at boot on a machine whose whole job is to serve one SQLite file. Offset arithmetic gets the right answer for every user who is not mid-DST-transition, and being an hour off inside that window is a smaller defect than a boot-time dependency on a remote zone file.

The offset must come from the browser because the server has none: a Fly machine runs UTC and the organizer is wherever they are.

**Alternatives rejected:**
- *Add `tzdata` and resolve a named zone.* Correct, and disproportionate. Revisit when a feature needs real zone arithmetic — recurring sessions would.
- *Ask the organizer to pick a time.* That is the custom picker, which was explicitly deferred this pass.
- *Compute the chips in JavaScript.* Then the label and the stored instant are derived in two places, and only one of them is testable.

**Consequences:**
- The first paint of `/groups/new` before the socket connects uses UTC and self-corrects on connect. Visible only as a chip label, and only to someone reading faster than the websocket.
- A DST transition inside the chip's window shifts the result by an hour. Documented in the module, and the honest cost of not carrying a zone database.
- `Consensus.Deadlines` is pure and has no database access, so its rules — including "next Thursday" meaning a week out when today is Thursday — are unit-tested across all seven weekdays and several offsets rather than reasoned about.

---

## D-032 — There is no global navigation bar

- **Date:** 2026-08-08
- **Status:** **superseded by D-041** — there *is* a global header and footer now, and `Layouts.app/1` renders them. The reasoning below is still true and is exactly why the header **coexists** with the wizard's progress bar instead of replacing it; only the "no shared bar" conclusion is dead.
- **Decision (history — no longer true):** ~~`ConsensusWeb.Layouts.app/1` renders the canvas, a centred column and the flash group — nothing else. Every screen draws its own header.~~ `Layouts.app/1` now also renders `ConsensusWeb.Chrome.header/1` and `Chrome.footer/1` around the screen's content (D-041). ~~`Layouts.account_menu/1` is a `<details>`-based avatar menu that screens place themselves~~ — that function is **deleted**; the header's `⋯` menu replaced it and kept its `<details>` implementation. `Layouts.avatar/1` survives unchanged and is still placed by the screens that use it in their body.

**Why (still true, and now the constraint on the global header rather than an argument against it):** the design gives each screen a different header, and each difference carries meaning. The home screen has a wordmark and an avatar; the wizard steps have a back button and a three-segment progress bar; the option editor has a close button and a destructive `Remove`. A shared bar above all of them would either duplicate the back affordance or push the progress bar down a row — and on a 390px phone there is no row to spare.

D-041's answer to that is not "it turned out not to matter". It is that **the shared bar owns the back affordance and the per-screen row gives it up**: `Sticker.step_progress/1` lost its chevron and kept its bar, the option editor's `✕` became the header's `‹`, and the row that is left is genuinely per-screen (a progress bar, an h1, a `Remove`). The duplication this entry predicted is real — the design frames contain it — and it is prevented by rule, not by luck (plan ruling 1 in `docs/plans/chrome-and-feedback.md`). The "no row to spare" cost is paid honestly and it is **larger than this paragraph first claimed**: measured in the browser the header is 48.00px and the footer 120.25px — **168px, 22% of a phone viewport**, not "about 110px" — and two screens had to give up `min-h-dvh` roots because of it. Size a screen against 168px. ~~That footer is frame `4a` rendered faithfully — four rows, 8px gaps, 10/11px padding~~ — the cleanup round rebuilt it on the *screen* frames' geometry per `IMPORT-NOTES.md` §4.2 (26px faces, `7px 14px 9px` padding), which is 97px in the frame; the 23px it is over that buys the three text rows a 26px touch target, and the trade is recorded under D-041's Consequences. Either way the number is not slack to trim.

A `<details>` element rather than a JS dropdown so the menu works before LiveView connects, closes on Escape, and needs no code of ours. **This part survives verbatim** — `Chrome.header/1`'s `⋯` is the same `<details>`, restyled as a 29px circle.

**Alternatives rejected (as of this entry; D-041 reversed the first one):**
- *One navbar with per-screen slots.* ~~That is a header component with an empty shell around it; the shell adds a layout constraint and no shared behaviour.~~ This is essentially what D-041 built, and the shared behaviour it turned out to have is the thing this entry could not see from one screen at a time: **no screen can forget a way out**. Four screens shipped with no way back at all under the per-screen rule.
- *Keep the generator's navbar on non-wizard screens only.* Two visual languages depending on where you are, which is exactly what the design avoids. **Still rejected** — D-041's three variants differ in one slot, not in language.

**Consequences:**
- D-024 is superseded — the element it describes is gone.
- ~~Every new screen owes its own header, including a way back. A screen with no way out is now a review finding, not something the layout catches.~~ Reversed by D-041: `Layouts.app/1` catches it. What a new screen owes now is the *content* of the chrome — a `back` route, a `context` string, the right `variant` — not the chrome itself.
- The desktop console reuses `Layouts.app/1` with `width={:wide}` rather than a second layout. **Still true**, and the chrome spans the wide column with it.

---

## D-033 — The test suite runs one case at a time, and production takes the write lock up front

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `test/test_helper.exs` starts ExUnit with **`max_cases: 1`**. Separately, `config/dev.exs` and the `:prod` block of `config/runtime.exs` set **`default_transaction_mode: :immediate`**, and `config/test.exs` gains `journal_mode: :wal` to match them. `async: true` stays on the cases that have it — under the sandbox it still means "own connection, own transaction, rolled back at exit", which is the isolation we want; it just no longer means "at the same time as its neighbours".

**Why:** SQLite permits one write transaction across the whole database file, and the Ecto sandbox holds each test's transaction open for the *entire* test. Two concurrent write-touching cases therefore collide by construction. Worse, SQLite cannot make the loser wait: a connection already inside a transaction that asks to upgrade to a write would deadlock if it blocked, so SQLite returns `SQLITE_BUSY` **immediately** and the `busy_timeout` handler never runs. That is why the failure looked so strange — `** (Exqlite.Error) Database busy` on an ordinary `INSERT INTO users` in a `setup` block, in whichever case happened to be second, and a suite that finished in 2.2 seconds while failing fifty tests. A five-second busy timeout that is never consulted costs nothing and buys nothing.

Measured at 430 tests: ~50 failures a run at the default `max_cases: 20`, still ~46 at `--max-cases 2`, **zero** at `--max-cases 1`. `journal_mode: :wal` and `default_transaction_mode: :immediate` were both tried in `config/test.exs` first and neither helped, because the transaction in question is opened by the sandbox, not by us. The suite runs in about 2.6 seconds serially, so there was nothing to buy back.

**The production half is a different bug with the same root**, and it is the one that would have hurt. Our own `Repo.transact/1` calls — `Accounts.set_admin/3`, `Accounts.delete_user/2`, `Activities.delete_activity/2`, `Activities.reorder_activities/3` — open deferred transactions too. Two organizers writing at the same moment on the single machine would have produced the same immediate `SQLITE_BUSY`, surfacing as a 500 rather than a short wait. `:immediate` takes the write lock at `BEGIN`, before any read snapshot exists, which is the state the busy handler *can* wait in. So the second writer queues for up to five seconds instead of failing instantly.

**Alternatives rejected:**
- *Raising `busy_timeout`.* It was never consulted. This is the trap the `sqlite` skill's "raising it further just turns a fast failure into a slow one" line half-anticipated — in this shape it turns a fast failure into the same fast failure.
- *Marking every LiveView test `async: false`.* Tried first, and it did cut failures from ~56 to ~27, which is exactly the kind of partial result that invites calling it fixed. The remaining failures were in `Consensus.ActivitiesTest`, an ordinary `DataCase`, which shows the problem was never specific to LiveView tests — only correlated with how long a case holds its transaction.
- *Serialising only the write-heavy files.* A rule nobody can apply correctly to a new test, enforced by nothing, that fails intermittently when they get it wrong.
- *Postgres.* A real answer to a problem we do not have. D-003 chose SQLite deliberately, and one machine with one file is the point.

**Consequences:**
- The `sqlite` skill's claim that "`async: true` against SQLite is safe here" was true at 323 tests and is no longer the whole story. That section is rewritten: async is safe *because the suite no longer runs cases concurrently*, not because concurrency was fine.
- Adding tests can no longer make the suite flaky at some unknown threshold, which is the failure mode that cost the most time here — the symptom appeared in files that had not changed.
- Wall-clock is now the sum of all cases. At ~2.6 s for 431 tests there is a lot of headroom, but a future test that sleeps or does real IO now costs the whole suite that time, not one core's worth.
- `:immediate` serialises our transactions slightly earlier than before. On a single-writer database that is a description of what was already happening, not a new cost.

---

## D-034 — A ballot validates outside the write lock, retries when it loses it, and never raises at a voter

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** (the `outcome/1` clause below is amended by D-047 §3, which split `:vetoes_only` out of `:no_votes`.) `Consensus.Voting.cast_ballot/3` does **every** pure and read-only check — id casting, ballot shape, participant re-read, group status, deadline, veto permission, "is this activity even in this group" — *before* `Repo.transact/1` opens. Inside the transaction there are exactly three statements: a primary-key re-read of the group, the conditional `UPDATE participants SET voted_at = ? WHERE id = ? AND voted_at IS NULL`, and one `Repo.insert_all/3` for every vote row. Both voter-facing entry points (`cast_ballot/3` and `create_participant/2`) `rescue` **`Exqlite.Error` and `DBConnection.ConnectionError`** into `{:error, {:database_busy, message}}`, and `cast_ballot/3` wraps itself in a bounded, jittered retry (`@busy_retries 2`, `@busy_retry_pause_ms 25..150`) before giving up. `ensure_all_in_group/2` bounds the client's id list by the group's own activity count before building an `IN (?, ?, …)`, and `outcome/1` reports `:no_consensus` when every option has been vetoed rather than leaving a completed group with no winner and no leader.

**Why:** this is the first **public, unauthenticated, deliberately burst-shaped** write in the app. Five friends tapping "send my votes" as the deadline chip turns red is the core use case, not an edge, and SQLite permits one write transaction across the whole file (D-033).

Measured on a real pool at production's settings (`pool_size: 5`, `default_transaction_mode: :immediate`, `busy_timeout: 5_000`, WAL), with the validation queries *inside* the transaction: 23 of 48 ballots refused at four simultaneous voters, 54 of 96 at eight — every one of them a `{:error, {:database_busy, …}}` raised on `BEGIN IMMEDIATE`, i.e. the voter's browser hung for the full five-second busy timeout and then lost the ballot. Past six voters, connections queued behind the stalled writers began exceeding the pool checkout timeout and raising `DBConnection.ConnectionError`, which the `Exqlite.Error`-only rescue did not cover — so a guest got a crashed LiveView instead of a message. `create_participant/2` had no rescue at all, which turned the `/join/:slug` front door into a 500 for a guest who had not yet seen the pool, because a controller has no error tuple to render.

The retry exists because the callers arrive together *by construction*: SQLite's busy handler backs off unfairly under several writers, so a loser can burn its whole timeout while others slip past. Jitter matters for the same reason — an unjittered retry rebuilds the same pile-up one interval later. Retrying the whole function is safe because a raise can only happen before the transaction commits, and `Repo.transact/1` rolls back anything in between; in the one ambiguous case (a raise at `COMMIT`), the retry's conditional `UPDATE` finds `voted_at` already set and answers `{:error, :already_voted}` — wrong but harmless, since the ballot did land.

The id-list bound is a separate, smaller bug with the same rescue as its symptom: `cast_ballot(participant, [valid_id | Enum.to_list(1_000_000..1_040_000)])` blew SQLite's variable limit and was reported as `{:error, {:database_busy, "too many SQL variables"}}` — telling a voter to try again later about input that can never succeed. A ballot can never legitimately name more options than the group has, so the bound is free and exact.

**Alternatives rejected:**
- *Keep the reads inside the transaction "for consistency".* They guard against nothing the conditional `UPDATE` does not already guard against, and they were the single largest contributor to lock-hold time (reads + `update_all` alone: 28 of 60 refused at five voters).
- *One `Repo.insert` per mark.* A round trip per approval, all of it with the write lock held.
- *Retry forever.* An unbounded retry under a deadline burst is a queue with no exit; two attempts plus the original is enough for a five-to-eight-voter burst and bounded for the LiveView calling it.
- *Rescue `RuntimeError` or `_` broadly.* `{:error, {:database_busy, …}}` is grepped for in production logs; mislabelling an unrelated failure as a busy database is how that stops meaning anything.

**Consequences:**
- `{:error, {:database_busy, message}}` is now a documented return of `create_participant/2` as well as `cast_ballot/3`. Callers must render it; `JoinController` in particular has to re-render its own screen rather than let it escape.
- `Consensus.Accounts.set_admin/3` and `delete_user/2` still carry the *narrow* `Exqlite.Error`-only rescue. They are organizer/admin-rate writes, not burst-shaped, so they were left alone deliberately — widening them is a reasonable follow-up, not a fix this decision requires.
- The retry sleeps in the caller's process. A LiveView casting a ballot can therefore block for up to ~3× the busy timeout plus jitter before answering. That is accepted: the alternative is losing the ballot.
- `outcome/1` exists because `tally/1` alone cannot distinguish "everybody vetoed everything" from "nobody has voted yet" — both are a list with no `leader?` and no `winner?`. **D-047 §3 added a third such state, `:vetoes_only`: ballots cast, part of the pool vetoed, and nothing that survived carrying an approval — which fell through to `:no_votes` and printed "Voting closed before anyone cast a ballot" over a `1/1 voted` avatar row.** There is deliberately **no** fallback to the least-vetoed option: "everyone gets one veto, vetoed places drop out" is the rule the organizer showed the group.
- [test/consensus/voting_concurrency_test.exs](../test/consensus/voting_concurrency_test.exs) is the regression guard, and it is the only case in the suite that executes two ballots at the same instant — see its moduledoc for what it does and does not discriminate.

---

## D-035 — MVP voting is unconditionally anonymous; the review screen states the rule instead of offering a switch

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `Consensus.Voting` is **structurally** anonymous in every mode: `tally/1` returns totals only, `participants/1` returns name/initial and *whether* someone voted, the PubSub message is `{:ballot_cast, group_id}` and carries nothing about the ballot, and there is no public function anywhere in the context that maps a participant to the options they approved. `Consensus.Activities.Group.anonymous` stays in the schema (default `true`) but nothing reads it. `ConsensusWeb.GroupLive.Review` no longer renders a toggle for it — the card states the rule (~~"Nobody sees who picked what — totals only"~~, now **"Anyone with the link sees who voted. Nobody sees what they picked — you included."** per D-049 §1, which found that half-statement repeated in five places and one of them contradicted by its own screen; `ALWAYS ON`) the way the veto card states its rule. **The behaviour below is unchanged and D-049 changed no code in `Consensus.Voting`** — only the sentences that describe it.

**Why:** the toggle was a promise the backend did not keep. It persisted, it round-tripped, an organizer could switch it off — and switching it off changed nothing anywhere, because the engine has no attribution to reveal. A user-visible setting that silently does nothing is worse than no setting: the organizer who turns it off has told their friends their names will show.

Making it *work* would mean building per-participant attribution, and that is outside the contract this feature was built to. [docs/plans/voting-loop.md](plans/voting-loop.md) specifies anonymity as an absolute — "`tally/1` must not return per-participant choices at all — not 'returns them and the template hides them'" — and specifies no behaviour whatsoever for a non-anonymous mode. Under PRD scope discipline that makes attribution a new feature, not a missing branch.

Structural anonymity is also the stronger property. A context that cannot produce the names cannot leak them through a template someone forgot to guard, and that is worth keeping even once a non-anonymous mode is built: attribution should arrive as its own explicitly-named function that refuses for an anonymous group, never as an extra key on `tally/1`.

**Alternatives rejected:**
- *Leave the toggle and document the no-op.* Documentation does not reach the organizer looking at the switch.
- *Delete the `anonymous` column too.* Scope discipline explicitly allows a Post-MVP feature to inform the shape of an MVP data model, and the column is where a real mode would land. Dropping and re-adding it is churn.
- *Wire a speculative `attributions/1` with no caller.* Unused API with no screen to shape it, in a feature whose web layer is not built yet.

**Consequences:**
- Design frame `03` draws a switch; we draw a statement. That is a deliberate deviation from the mockup, recorded here rather than left for a fidelity review to "fix" back in.
- PRD product invariant 6 ("anonymous voting is a first-class mode") is satisfied in the direction that matters — it is the *only* mode — and is not yet satisfied in the sense of offering a contrasting one. Re-opening that is a new decision.
- Pinned by "anonymity does not depend on group.anonymous" in [test/consensus/voting_test.exs](../test/consensus/voting_test.exs), which sets `anonymous: false` and asserts the returned shapes are unchanged and carry no names. If someone later wires attribution, they have to come to that describe block and say so.

---

## D-036 — A cast ballot is locked; there is no "change my ranking"

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `participants.voted_at` is the lock. Once it is set, `Consensus.Voting.cast_ballot/3` refuses with `{:error, :already_voted}` and there is no update path — no `recast_ballot/3`, no delete-and-resubmit. The lock is taken by a conditional `UPDATE ... WHERE voted_at IS NULL` inside the ballot's transaction, so two tabs double-submitting produce exactly one ballot and one refusal. Design frame `05b` draws a **"Change my ranking"** button; we do not build it, and that footer slot renders the locked confirmation instead.

**Why:** a vote that can be changed after the fact is a vote that has to be re-tallied, re-broadcast and re-explained, and it opens the obvious abuse — watch the live tally, then move your approval to whatever is winning. The whole product runs on a hard deadline (PRD product invariant 3) precisely so that the state at close is the state everyone agreed to.

It is also what makes the write cheap. An immutable ballot needs one conditional `UPDATE` and one `insert_all`; a mutable one needs a delete-and-reinsert inside the same lock every time, on the single-writer database this app runs on (D-033, D-034).

**Alternatives rejected:**
- *Allow a change until the deadline.* Defensible product-wise, and it turns the tally into a moving target that a participant can chase. Revisit only with a real design for it.
- *Enforce the lock in the LiveView only.* A `disabled` attribute is a client-side hint; the event can be pushed anyway. Same reasoning as the sudo-mode UI in D-021.

**Consequences:**
- Re-entering `/join/:slug/vote` once `voted_at` is set must redirect to results. The lock is a route-level fact, not a greyed-out button.
- A voter who mis-taps has no recovery. Accepted for MVP; the ballot screen therefore has to make the selected state unmistakable before submit.
- `votes` rows are effectively append-only, which is what lets D-037 be a pure refusal rather than a repair.

---

## D-037 — The activity pool freezes when the vote opens

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `Consensus.Activities.add_activity/3`, `update_activity/3`, `delete_activity/2` and `reorder_activities/3` all refuse with `{:error, :pool_locked}` unless the group is still a `:draft`. (`add_activity/3` previously returned `{:error, :group_not_open}` and allowed `:voting`; that atom is gone.) `ConsensusWeb.GroupLive.Options` bounces a non-draft group to `03 review`, and `ConsensusWeb.GroupLive.Review` — which `HomeLive` still sends a `:voting` group to — drops its drag handle, ↑/↓ pair, `Sortable` hook and `×` once the group leaves `:draft`.

**Why:** `votes.activity_id` references `activities` with `ON DELETE CASCADE`. Deleting an option people had already voted on silently destroyed their vote rows while `participants.voted_at` stayed set — and the ballot is locked (D-036), so they could not recast. Verified end to end before the fix: publish, have a guest approve two options, call `Activities.delete_activity/2` (exactly what the `×` on `03` does), and the guest's ballot drops from two votes to one with `{:error, :already_voted}` on any retry. Their submission is permanently short one choice and nothing anywhere says so.

Reordering is the same bug more quietly: `Voting.tally/1` breaks ties by `activity.position`, so renumbering a pool mid-vote retroactively changes who is winning. Renaming an option changes what people agreed to. None of the three has a repair — the vote rows are append-only by D-036 — so the only correct move is refusal.

The refusal lives in the context because that is the only place it can be enforced. `GroupLive.Options`' route had no status guard and `GroupLive.Review` renders for `:voting` groups on purpose, so both screens were reachable, and a `phx-click` can be pushed at any socket the organizer can mount. Hiding the controls is the courtesy; `Consensus.Activities` is the enforcement. Same split as the sudo-mode UI in D-021.

**Alternatives rejected:**
- *`ON DELETE RESTRICT` on `votes.activity_id`.* Turns the bug into an `Ecto.ConstraintError` at a random call site, and breaks the organizer-deletion cascade that `delete_user/2` depends on.
- *Allow edits and re-tally.* There is nothing to re-tally: the votes are already gone by the time anyone notices.
- *Allow `update_activity/3` (a description tweak is harmless).* A rename is not harmless, and one changeset covers both. A single rule that is easy to state beats a per-field carve-out nobody will remember.
- *Guard only in the LiveViews.* Leaves the destructive path open to a pushed event and to any future caller.

**Consequences:**
- An organizer cannot fix a typo after publishing. That is the cost, and it is smaller than destroying a friend's ballot; the wizard's `03 review` step exists precisely so the pool gets a last look before it freezes.
- `ConsensusWeb.JourneyTest` now proves the pasted-link image survived by reading `03 review` rather than the per-option editor, and additionally asserts the editor redirects. The editor is unreachable for a published group by design.
- D-029's activity-lifecycle picture gains a second frozen boundary: `:draft → :voting` freezes the pool, not just the group's own fields.

---

## D-038 — SQLite runs on one connection, and the durability setting is pinned rather than inherited

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `Consensus.Repo` uses **`pool_size: 1`** in `config/dev.exs` and as the production default in `config/runtime.exs` (`POOL_SIZE` still overrides it). `synchronous: :normal` is now written out in both files. `config/test.exs` is deliberately untouched — it runs `Ecto.Adapters.SQL.Sandbox`, a different pool implementation whose size governs sandbox checkouts, not write contention. Guarded by [test/consensus/repo_config_test.exs](../test/consensus/repo_config_test.exs).

**Why:** SQLite permits exactly one write transaction across the whole database file. Extra pool slots therefore cannot buy write concurrency — there is none to buy. What they do buy is *contenders*: five connections racing a lock that was never shareable, arbitrated by a busy handler SQLite's own documentation says makes no fairness guarantee about which waiter wins. A loser can burn its entire five-second timeout while later arrivals slip past it.

Measured on the realistic worst case — **fifteen voters submitting inside a deadline burst**, at production's own settings (`default_transaction_mode: :immediate`, `busy_timeout: 5_000`, WAL), five repetitions pooled:

| `pool_size` | arrival window | p50 | p95 | max |
|---|---|---|---|---|
| 5 (previous) | 10 s | 3.2 ms | 35 ms | 207 ms |
| 5 (previous) | 2 s | 32 ms | **25,762 ms** | **38,888 ms** |
| 1 | 2 s | 3.6 ms | **10.6 ms** | 127 ms |

At `pool_size: 1`, sixty-four simultaneous ballots ran at p50 74 ms / max 129 ms with **zero** refusals — no ceiling this product will find at its stated scale of dozens of users. The knee for the old config was roughly **two genuinely concurrent writers**.

Phase timing localised 100% of the delay to `BEGIN IMMEDIATE`; every pre-transaction read stayed sub-millisecond. So D-034's work — hoisting validation out of the transaction — was correct and is not what was left broken. Setting `synchronous: :off` changed nothing, which is the evidence that this is lock contention rather than disk: the numbers should therefore reproduce on Fly, where absolute latencies will be higher than these (Mac, local SSD) but the shape will not change.

Extra slots degraded **reads** too — a 5,431 ms read tail at `pool_size: 5` against 15.6 ms at 1 — which is what makes D-013's "buys concurrent readers only" wrong rather than merely incomplete. That line is struck through in place.

`synchronous: :normal` is pinned at its existing default value, so it changes no behaviour today. The point is that the durability trade should be a decision somebody made: under WAL, `:normal` fsyncs at checkpoint rather than at every commit, so a BEAM crash or a `fly deploy` cannot lose a committed ballot, but a host power loss or kernel panic can lose the tail of the WAL. That is accepted, because this deployment's real durability exposure is the volume snapshot's 24-hour RPO (D-019), not fsync timing.

**Alternatives rejected:**
- *Leave it at 5 and raise `busy_timeout`.* Makes the stall longer, not rarer. The voter still waits.
- *Leave it at 5 and add more retries.* D-034 already retries; the retries were what kept the loss at 45% rather than higher. Retrying into a contended lock is a queue with no exit.
- *`synchronous: :off`.* Measurably no faster here — contention, not disk — and it trades real durability for nothing.
- *Change `config/test.exs` to match.* It uses a different pool implementation. Matching the number would be cargo-culting a value whose meaning differs, and risks breaking 595 passing tests for no production benefit.

**Consequences:**
- Every database operation in the app now serialises through one connection. This is fine *because* of D-034 and D-013: the write transaction is three statements, and reads are sub-millisecond. It would not be fine if a slow query were ever added — a single long read now blocks everything, where before it blocked one slot of five.
- `POOL_SIZE` remains an escape hatch. Raise it only with a measurement, and amend this entry when you do.
- The monitorable trigger for outgrowing SQLite is **any** occurrence of `[voting] ballot refused after` in production logs — that string means a ballot was lost — plus a capacity trigger of >50 participants submitting inside one 5-second window, or ballot p95 over 1 second. Full analysis and the migration costing are in [docs/sqlite-capacity-review.md](sqlite-capacity-review.md).
- The review that produced these numbers also found that backups, not concurrency, are this deployment's larger risk: 24 h RPO, a restore runbook never executed (D-019), and `TODO.md` §7 recommending an `fly sftp get` of the `.db` **without its `-wal` sidecar**. That is not fixed here and remains open.

---

## D-039 — Resend is the mail provider, configured only when its key is present

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `config/runtime.exs` configures `Swoosh.Adapters.Resend` for `config_env() == :prod` **when `RESEND_API_KEY` is set and non-empty**, and leaves D-014's `Swoosh.Adapters.Logger` in force when it is not, warning loudly at boot. `config/prod.exs` already supplies the required `Swoosh.ApiClient.Req`. The `From` address moved out of the source into `MAIL_FROM` / `MAIL_FROM_NAME`, read by `Consensus.Accounts.UserNotifier.sender/0`.

**Why:** the app had a mail *adapter* but no mail *provider*, so magic-link login and the confirm-your-email-change flow reached nobody in production. Resend was chosen by the repo owner; it needs one API key and an HTTP client this app already depends on.

The configuration is **conditional on purpose**, and the conditional is the substantive part of this decision:

- **The app must stay deployable before the secret exists.** `SECRET_KEY_BASE` raises at boot because nothing works without it. Mail is the opposite — invariant 9 says delivery is best-effort and must never fail a request — so a missing mail key must never cost a boot. Raising would make the first deploy of this very change fail on a machine whose secret is not set yet, which is exactly the machine that has it.
- **A silent fallback would be worse than a loud one.** When the key is absent the boot warning is the only thing that will ever explain why a magic link did not arrive, so it names the symptom, the blast radius, and the fix (`fly secrets set RESEND_API_KEY=...`).

The hardcoded `contact@example.com` sender had to go regardless: Resend rejects a `From` whose domain is not verified in its dashboard, and `example.com` can never be verified by anyone. The fallback is Resend's `onboarding@resend.dev`, the one address any account may send from unverified, so a first deploy delivers to the account owner rather than erroring.

**Alternatives rejected:**
- *Raise when `RESEND_API_KEY` is missing.* Turns a degraded-but-working deployment into no deployment, for a subsystem the app is explicitly designed to run without.
- *Hardcode the adapter unconditionally.* Every dev/CI boot without the key would then attempt real HTTP to Resend and fail per-send instead of once at boot.
- *Keep the sender in source and verify `example.com`.* Not possible; nobody controls it.
- *Put the key in `config/prod.exs`.* Compile-time, and it would bake a secret into the release image.

**Consequences:**
- `RESEND_API_KEY` must be set with `fly secrets set` before magic-link login works in production. Until then the boot warning fires on every deploy and behaviour is exactly D-014's.
- `MAIL_FROM` must be an address on a domain verified in Resend, or delivery fails per-send. Unset means `onboarding@resend.dev`, which only delivers to the Resend account owner's own address.
- The two settings live in **different places on purpose**: `RESEND_API_KEY` is a Fly secret, `MAIL_FROM` is a plain `[env]` entry in `fly.toml` (set to `consensus@marketfinder.us`). A sender address is in the header of every message we send, so it is config rather than a secret, and `fly.toml` keeps it diffable and reviewable — Fly secrets are write-only and restart the machine on every `set`, neither of which is wanted for ordinary config.
- `.env.example` is now a real file documenting all of these; `.env` stays gitignored.
- CLAUDE.md's "Known gap, not an invariant" paragraph, README and TODO all had to change: they said production could not deliver mail at all, which stops being true the moment the secret is set.
- Invariant 9 is untouched and still binding. `UserNotifier.deliver/3` keeps its `catch`, and a Resend outage must remain a logged `{:error, reason}` rather than a failed request.

---

## D-040 — Consensus is served from `dinner.isourthing.com`, not `<app>.fly.dev`

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `PHX_HOST` is **`dinner.isourthing.com`**, a custom domain with a Fly-issued certificate, and `primary_region` is **`ewr`**. `fly.toml`'s `app` stays `consensus-app` — the Fly app name and the hostname are now different things. `test/consensus/deploy_config_test.exs` no longer derives `PHX_HOST` from `app`; it asserts against a recorded `@serving_hostname` constant instead, and gained a second test pinning `app` itself, which lost its only guard when the derivation went away.

**Why:** the domain is the product's actual address. `PHX_HOST` is not cosmetic — it becomes the endpoint's `:url` host, `check_origin` defaults to `true` in production and validates every LiveView socket's `Origin` against it, and every page in this app is a LiveView. Pointing it at `consensus-app.fly.dev` while people arrive at `dinner.isourthing.com` 403s every socket upgrade, leaving the app completely non-interactive while `GET /` and `/health` both keep answering 200 and Fly reports the machine healthy.

That is not hypothetical here. The deploy that preceded this entry booted with

    check_origin: ["https://example.com", "//another.com:888", "//other.com"]

— `example.com` being `runtime.exs`'s fallback when `PHX_HOST` is unset — so LiveView was broken in production while every external signal said healthy. This is D-023's failure mode, observed rather than predicted.

CLAUDE.md's instruction for this situation was explicit: *"If this app ever moves to a custom domain, **edit** that first test and record the move in `decisions.md` — do not delete it."* The test is edited, not deleted, and its failure message now names all three things that have to move together: the constant, `fly.toml`'s `PHX_HOST`, and the certificate.

**Alternatives rejected:**
- *Keep `PHX_HOST = consensus-app.fly.dev` and let the custom domain redirect.* Anyone arriving at the custom domain gets a dead app, and the certificate already issued for it says that is where people are meant to arrive.
- *List both hosts in `check_origin`.* Workable, but `PHX_HOST` still has to pick one for `:url`, and every generated absolute URL — including the `/join/:slug` share link an organizer sends to friends — would carry the wrong host. The share link *is* the product.
- *Delete the `PHX_HOST` test now that it cannot derive its expectation.* That would remove the guard precisely when the config got harder to check by eye.
- *Move the region to `iad` to match what `fly.toml` used to say.* No benefit; the machine, volume and certificate are all in `ewr`, and a volume cannot attach to a machine in another region. `ewr` and `iad` are both US East.

**Consequences:**
- `app` and hostname are now independent, so renaming the Fly app no longer implies a hostname change and vice versa. The new `app` test exists because of exactly that loosening.
- CI's `docker` job `sed`s `PHX_HOST` out of `fly.toml` and asserts `/health` and a websocket handshake under it. It now exercises a genuinely non-local hostname, which is a stronger test of the `force_ssl` `paths:` exclusion than `consensus-app.fly.dev` was — `localhost` and `127.0.0.1` are excluded wholesale by the sibling `hosts:` rule, and neither of those applies here.
- Certificate renewal is now a production dependency. `fly certs list -a consensus-app` is the check; an expired or removed cert takes the app down in a way `/health` will not report.
- The volume was recreated as `consensus_data` at `/data` in the same change (see the deployment notes in TODO.md). The previous `name` volume at `/mnt/name` was an artefact of an accidental `fly launch`; `/data` is the path the Dockerfile prepares with `RUN mkdir -p /data && chown nobody:root /data`, so mounting anywhere else defeated that preparation and the boot preflight that depends on it.

---

## D-041 — There is a global header and footer, and every screen wears them

- **Date:** 2026-08-08
- **Status:** settled — **supersedes D-032**
- **Decision:** `ConsensusWeb.Chrome` (`lib/consensus_web/components/chrome.ex`) holds `header/1` and `footer/1`, built from design frame `4a` (`docs/design/screens/4a-0-pair-in-the-footer-header-drops-to-recommended.html`) and the rulings in `docs/plans/chrome-and-feedback.md`. **`ConsensusWeb.Layouts.app/1` renders both itself**, around the screen's own content, so a screen cannot ship without them; a screen contributes only `back` (or `back_patch`), `context`, `variant` and `current_path`, new `Layouts.app/1` attributes passed straight through. `ConsensusWeb.Chrome` is imported *and* aliased in `ConsensusWeb.html_helpers/0` alongside `CoreComponents` and `Sticker`.

**The header is `sticky top-0 z-40`; the footer is not.** Since this header carries the *only* back affordance and the *only* account menu on every screen, a page taller than the viewport scrolling it away is a navigation dead end. Both pinned would spend ~168px of a 760px phone viewport on chrome, so the footer stays in the flow. Its `z-40` sits **above** the flash group's `z-30` deliberately — this header is the only way back on every screen and nothing may cover it, the flash card least of all, since a flash is by definition rendered on the screen someone has just landed on. (This sentence read "below the flash card's `z-50`" until the cleanup round; nothing in `lib/consensus_web/` renders at `z-50` any more. See the flash entry under Consequences for the whole history.)

**`context` is for state, never for the page's name.** It is the frame's `LIVE SESSION`: `STEP 2 OF 3`, `ADMIN`, `SHARE`. It must never repeat a string the screen's own body already shows — five screens shipped `PRIVACY`/`Privacy`, `ABOUT`/`About us`, `HOW IT WORKS`/`How it works`, `FEEDBACK`/`Feedback` and `EDIT OPTION`/`Edit option`, the same word twice in the same uppercase treatment ~110px apart. Where the body's `<.eyebrow>` already names the screen, the slot stays empty.

**What is in the header.** A 29px circular `‹` back control (omitted entirely when `back` and `back_patch` are both `nil` — never a dead circle), the app icon + `Consensus` wordmark linking to `/`, and then one of three right-hand treatments. The header has `min-h-[48px]` so every variant is the frame's height: without it the height is set by the tallest child, so a variant with no circles rendered at 37.75px and navigating between them shifted the page. `back_patch` is the same control done as a `live_patch`, for the one screen whose back destination is its own LiveView (`GroupLive.Options`' editor closing to its own pool) — a `navigate` there would tear the socket down and cancel any in-flight `LinkPreview` `start_async`.

| `variant` | Right-hand side | Used by |
|---|---|---|
| `:app` (default) | the DM Mono context slot, then the 29px `⋯` menu | every screen this app owns, signed in **or** out — the wizard, review, share, results, admin, settings, and the four auth screens |
| `:public` | the yellow `Create your own →` pill; **no `⋯`, no `‹`** | the whole `/join` tree — `/join/:slug`, `/join/:slug/vote`, `/join/:slug/results` |
| `:marketing` | a plain `Log in` link (`Sign in` until D-048); **no `⋯`**, but it **keeps the `‹`** | `/`, `/about`, `/privacy`, `/how-it-works`, `/feedback` **while signed out** — those same routes render `:app` for a signed-in visitor. `/` passes no `back` and so draws no circle; the other four are reached from the footer of every screen in the app and would be dead ends without one (plan ruling 3, amended) |

**What is in the footer** on `:app` and `:marketing`: `How's this going?` and the two 26px face buttons (mint smile → `/feedback?mood=happy`, peach frown → `/feedback?mood=sad`), then `About us · How it works · Privacy`, then the `marketfinder.us` line and `Made with ❤️ in Philadelphia`. ~~28px~~ — the pair was built from frame `4a` at 28px with a 16px glyph, a 9px gutter, an 11px label and `10px 14px 11px` of container padding; `docs/design/IMPORT-NOTES.md` §4.2 rules explicitly against exactly that (*"4a is an enlarged schematic of the pattern, not a screen. Build the 26px version"*) because all eleven real screen frames draw `26px` / `15px` / `gap:8px` / `10.5px` / `7px 14px 9px`. The cleanup round moved it to the screen frames' numbers. **On `/feedback` the pair is dropped entirely** — see the Consequences bullet on it.

~~**On `:public` the footer is the two credit lines and nothing else**~~ **— history, reversed 2026-08-09. The footer is now identical on `:public`**, which is what the brief asked for (*"the same footer but a simplified header"*), and the header's wordmark is inert text rather than a link to `/`. The reasoning below was right about the risk and wrong about the remedy: the danger is real, and it is closed by `confirm` — `JoinLive.Ballot` passes `footer_confirm` beside the `pill_confirm` it already passed, so every footer control prompts once anything is selected and none prompts before — rather than by deleting the controls. A guest stuck mid-ballot is precisely the person with something to report, and the screen the drop-off metric is measured on is the last one that should hide the report button. Pinned by "on :public every control takes the caller's confirm" in `chrome_test.exs`. A guest's ballot lives entirely in socket assigns until `Voting.cast_ballot/3` runs, and a guest has no account and no history of the group — every link off that screen silently discards their selections and leaves them with no route back except the original share link in whatever chat app they came from. Rendering the pair and the three standing links there put five such links, plus the wordmark, under the "Send my votes" button, on the exact screen product invariant 1 and the "guest drop-off under 5%" metric are measured on. The `Create your own →` pill is the one deliberate door out, and it says so.

**The footer drops the standing link for the page it is on, and every other one carries `?return_to=<the path it was tapped on>`.** `/about`, `/how-it-works`, `/privacy` and `/feedback` are reachable from the footer of every screen in the app, so `back={~p"/"}` meant tapping one from step 2 of the wizard dropped the organizer on the home list. The path comes from `@current_path`, which `ConsensusWeb.CurrentPath` — an `on_mount` hook declared once, in `ConsensusWeb.live_view/0`, so no `live_session` has to remember it — keeps in sync via a `:handle_params` lifecycle hook. It is read back through `CurrentPath.safe_return_to/1`, which rejects anything that is not a single-slash local path: `return_to` is a query parameter and therefore attacker-controlled, and a `<.link navigate>` built straight from it would be an open redirect wearing this app's chrome. `@current_path` also suppresses **every control in this chrome** that points at the page you are already standing on — the `⋯` entries signed in and signed out, the whole `⋯` when that would leave one entry, the footer's own standing link, the footer's whole mood pair on `/feedback`, and the wordmark. See the Consequences below for what shipped half-done here and what the cleanup round changed.

**Where the back control lives.** In the header, and **only** there. `Sticker.step_progress/1` lost its chevron and its `back` attribute; `GroupLive.New` and `GroupLive.Options` pass the route they used to give it to `Layouts.app/1`'s `back` instead. The option editor's `✕` is gone the same way — it was a close-to-parent, i.e. a back control. `AdminLive.Users`' "Back to app" button and the four auth screens' `Consensus` wordmark links are deleted for the same reason. `Layouts.account_menu/1` is deleted outright; the `⋯` menu is its replacement and keeps its `<details>` implementation verbatim. `Layouts.avatar/1` stays and is still placed by the screens that use it in their body (`GroupLive.New`'s GROUP row).

**Why:** the re-imported design puts this chrome on every frame, and the reason is not decoration. Four of the five screens that had *no* way back — `04 share`, `05` results, the two `/join` results screens — were reachable by link and left a visitor with nothing to press. That is the acceptance bar of `docs/plans/chrome-and-feedback.md` ("no user gets stuck") failing structurally rather than screen by screen, and a per-screen convention cannot fix it because the failure mode *is* a screen forgetting. Putting it in `Layouts.app/1` makes forgetting impossible. The footer additionally gives feedback capture and the three standing pages one home, instead of each screen deciding whether to link them.

**Alternatives rejected:**
- *Have each screen call `<Chrome.header>` / `<Chrome.footer>` itself.* Fourteen call sites, and the one that gets missed is exactly the dead end this exists to close. The components stay public for tests, but nothing in `lib/` calls them except `Layouts.app/1`.
- *Put the chrome in `root.html.heex`.* It has to sit inside the centred 440px column; emitted at the document root it would span the whole viewport at desktop width and detach from the app.
- *Keep the frames' second back button.* `01` and `02` literally stack the global `‹` and the wizard row's `‹`. Two controls that look like "back" and may go to different places is the confusion this work removes (plan ruling 1).
- *Tangerine for the public CTA.* Tangerine is the one forward action per screen, and on the ballot that is "Send my votes". The pill is yellow at rest and only goes tangerine on hover (plan ruling 2).
- *A `⋯` for `:public`.* A guest has no account, wants none, and the pill already covers the one thing they might want next. Dropping it keeps the guest header to two elements.

**Consequences:**
- **D-032 is superseded**, and annotated in place — its reasoning survives and is *why* the header coexists with the wizard's progress bar rather than replacing it.
- `Layouts.app/1` grew a `<main class="flex min-h-0 flex-1 flex-col">` around the inner block, **inside** a plain outer `<div>` rather than inside `<main>` as it first shipped. The chrome's `<header>` is the page's `banner` landmark and its `<footer>` is `contentinfo`, and neither is either while nested in `<main>`; screens draw their own `<header>` rows (HomeLive's "Your sessions"), which stay generic inside `<main>` exactly as they should. Two screens that set `min-h-dvh` on their own root (`JoinLive.Entry`, `JoinLive.Ballot`) changed it to `flex-1`: with the chrome inside the same column, a full-viewport child pushes the page past the viewport and produces two scrollbars.
- **`CoreComponents.flash/1` is no longer `fixed` at all, and must not become `fixed` again.** It shipped as `fixed left-1/2 top-4 z-50`, which landed squarely on the 48px header — measured, it covered ~24 of each 29px circle and swallowed their clicks — on the most ordinary transitions there are ("Welcome back!", "Zahav saved.", a require-auth bounce to `/users/log-in`, the pool-locked bounce from `/groups/:id/options` to review). Before this piece each screen drew its own navigation and that was cosmetic overlap; now the header is the only way back and the only account menu, so it was a navigation failure. Moving it to `top-[56px]` cleared the header and **landed on the next thing on the page instead**: measured at 420×900 it hid the `<h1>` outright on `/` signed in ("Your sessions", y=62–89 under a flash at y=56–116), on `/users/log-in` ("Log in") and on `/admin/users` ("Users"), and cut the wizard's `2/3` progress bar and the first line of "Add the options" in half. A flash is shown on precisely the screen someone lands on right after acting, so the screen whose title it hides is the screen whose title matters most — and a Phoenix flash persists until it is dismissed or navigated away from, so this was not a momentary overlap. There is no safe hard-coded `top`: each screen puts something different first. `left-1/2 -translate-x-1/2` was a second, quieter bug with the same shape — it centres on the **initial containing block**, not the viewport, so on `/admin/users` (whose table grew `documentElement.scrollWidth` to 648px in a 420px viewport) the card rendered at x=132 with its dismiss ✕ off-screen and untappable. `Layouts.app/1` renders `flash_group/1` **inside the centred column, directly between the header and `<main>`**, which is what bounds it to the column and fixed the `scrollWidth` centring. ~~In the flow, so a flash displaces content instead of occluding it.~~ **That last half is history: `static` was a third failure of the same kind and the cleanup round replaced it with `sticky top-[40px] z-30`.** A flash is by definition rendered right after an action, and on a page taller than the viewport the action is very often taken while scrolled down: measured at 420×900 on `/admin/users` (`scrollHeight` 1177), pressing Promote from `scrollY = 345` rendered the card at `top: -297px`, entirely above the viewport — a privileged, audit-logged write with no visible confirmation at all. The same container holds LiveView's `#client-error` / `#server-error` reconnect banners, so a dropped socket was silent for a scrolled reader too, including a guest mid-ballot. `40px` is the header's measured 48px height minus the `mt-2` that `flash/1` carries, so the **card** lands at exactly 48px, flush under the header's bottom border; offsetting the container by the header height instead pinned the card at 56px and left an 8px transparent slit the page scrolled through, which reads as a rendering fault rather than as spacing. `z-30` sits below the header's `z-40` (nothing may cover the only way back) and above the `z-10` that is the highest anything in a screen's own body stacks. The `mx-4 mt-2` margins live on `flash/1` rather than on the group because the two connection-error flashes are always in the DOM and merely `hidden` — padding on the container would reserve their space on every screen forever.
- `GroupLive.Share`'s bottom sheet moved from `absolute inset-x-0 bottom-0` inside an `overflow-hidden` parent to `mt-auto` in the flow, and **the dimmed scrim behind it is gone**. It was never a `fixed` modal — the sheet is in the column's normal flow and the chrome above it is fully interactive — so dimmed content under an undimmed, clickable header read as a rendering bug rather than a deliberate scrim, and dimming the header with it would have hidden the only way off the screen. With ~168px of column now spent on chrome, an absolutely-positioned sheet taller than its container silently clipped its own top off.
- **`/admin/dashboard` is the one route that does not wear the chrome, and cannot.** `Phoenix.LiveDashboard` declares its own `live_session` *and* its own layout, so `Layouts.app/1` never runs for it; wrapping it means forking a third-party LiveView. It offers nothing to configure in place of the `‹` either — `home_app:` was tried and only labels the app on LiveDashboard's own home page, verified in a browser, so it was removed again rather than left in the router implying something it does not do. This is accepted: nothing in `lib/` links there, it is reachable only by typing the URL, and an administrator who typed a URL has a back button. Read "every screen" in this entry as "every screen this app renders".
- ~~**The footer's feedback pair ships ahead of the form it asks for.**~~ **History — closed by D-042.** When this entry was written `/feedback` was a stub that named the mood the face carried and said plainly that nothing was recorded, and two critics split on whether the pair should ship at all before the form existed (the flow critic wanted it held back; the design critic ruled it acceptable while the copy stayed blunt). Frame `4a`, the ratified chrome, puts the pair in the footer as the whole point of the frame, so it shipped with the dead end closed (`return_to`) and the copy blunt. **D-042 built the form, the `feedback` table and `Consensus.Feedback`, so the pair is now done and the old instruction not to describe it as done no longer applies.** The reasoning above is kept because it is the standing rule for shipping any affordance ahead of what it asks for.
- Three body-level "Back to Consensus" links and the option editor's "Cancel" are deleted: each resolved to the same route as the header's `‹`, which is plan ruling 1's duplicate back affordance, and on `/privacy` and `/feedback` the duplicate was also wearing the screen's one tangerine. The option editor's destructive `Remove` was tangerine too — restyled to ink, so `Save option` is the screen's only tangerine.
- `/how-it-works`'s "Start something →" navigates to `/groups/new` signed in and `/users/register` signed out. It used to navigate to `/`, where the user had to press a second button with the same label.
- ~~`AdminLive.Users`' sudo flash no longer promises "You will come back to Admin → Users."~~ **History — superseded by D-045**, which built the thing this bullet said would need its own entry. The diagnosis was right: `user_return_to` was written only by `maybe_store_return_to/1`, a plug on GET requests, so a LiveView-originated navigation stored nothing and `UserAuth.signed_in_path/1` landed an already-authenticated conn on `/users/settings`. The remedy has changed from removing the promise to keeping it: `require_sudo/2` now navigates to `/users/log-in?return_to=/admin/users`, `UserLive.Login` carries it as a hidden `user[return_to]` on the **password** form, and `UserAuth.store_return_to/2` validates it through `ConsensusWeb.CurrentPath.safe_return_to/1` before `log_in_user/3` honours it. See D-045 for why the magic-link half deliberately does not carry it.
- **Four new routes exist so that no footer link is a dead end**: `/about`, `/how-it-works`, `/privacy` and `/feedback`, all in the existing `live_session :current_user`. ~~All four are placeholders.~~ **History — D-042 replaced all four bodies**: `/how-it-works` is frame `00b` with its false copy rewritten, `/feedback` is frame `00c` with a real form and a `feedback` table behind it, and `AboutLive`/`PrivacyLive` are short, true pages stating only what the code actually does.
- `--color-faint-soft: #A9B7AE` was added to the `@theme` block for the footer's `·` separators (the name comes from the plan's token table).
- `ConsensusWeb.Chrome.header/1` and the unused `ConsensusWeb.CoreComponents.header/1` are both imported app-wide, so a bare `<.header>` is now an ambiguous call. Nothing calls it; write `<Chrome.header>`, or call the CoreComponents one fully qualified.
- **Nothing in the header points at where you already are, and that rule now covers every control in it** (the footer's own two cases are the bullet below this one)**.** The first cut wired `on_path?/2` only into the signed-out `⋯` entries while this entry and `Chrome`'s moduledoc both described the suppression as general — so `/users/settings` offered "Settings" and `/admin/users` offered "Admin", and on `/users/settings` the header's four links read `["/", "/", "/users/settings", "/users/log-out"]`. Three additions close it: (a) the signed-in Settings and Admin entries take the same guard; (b) **the whole `⋯` is dropped when it would open on a single entry**, which is exactly the two auth screens — the one survivor duplicates the form's own "Already have one? Log in" 40px below it, and a `⋯` that opens to reveal one redundant link reads as broken; (c) **the wordmark goes inert** (a `<span>`, the shape `:public` already had) whenever the screen has a `‹` at all, or the visitor is standing on `/`. ~~Whenever `back` resolves to `/`.~~ **That narrower rule is history — it shipped first and the cleanup round widened it.** `back == "/"` covered the two-links-to-`/`-9px-apart duplication on eight screens (the auth screens, `/admin/users`, `/groups/new`, results, review-once-voting), but it left `/groups/:id/options` and `/groups/:id/review` carrying **two unlabelled exits 9px apart going to different places**: the `‹` one wizard step back, the wordmark abandoning the wizard for `/`. That is the same ruling-1 duplication in the form that is harder to recover from — a user who cannot predict which of two adjacent controls does what is worse off than one who cannot tell two identical destinations apart. The wordmark is now a link home only on a screen with no back control, which is where a home affordance earns its place.
- **The `:marketing` log-in link's `on_path?` guard was deleted as dead code.** It suppressed itself on `/users/log-in`, which this entry's own variant table puts on `:app`; the combination cannot occur, and the test covering it passed trivially. **The `:marketing` variant does keep the back circle**, which is a deviation from plan rulings 2 and 3 as written — a standing page reached from the footer of every screen in the app and given no `‹` is the dead end this work exists to close. Ruling 3 has been amended in place to say so rather than left disagreeing with the code.
- **`Layouts.admin?/1` moved to `Consensus.Accounts.Scope.admin?/1`.** `ConsensusWeb.Layouts` imports `ConsensusWeb.Chrome` through `html_helpers/0`, and `Chrome` was calling `Layouts.admin?/1` back — a mutual dependency for one two-clause predicate about a `%Scope{}` that has nothing to do with layouts. It compiled only because the call was remote; an `import ConsensusWeb.Layouts` in `chrome.ex` would have made it a compile deadlock.
- **`footer/1` drops the standing link for the page it is rendering on, and passes an inbound `return_to` through rather than wrapping it.** From `/how-it-works?return_to=/groups/5/options` the footer's own "How it works" navigated to `/how-it-works?return_to=%2Fhow-it-works%3Freturn_to%3D…` — a byte-identical screen whose `‹` then went to another byte-identical screen, with the wizard step the organizer actually came from two presses away and nothing on screen saying so. The pass-through goes through `CurrentPath.safe_return_to/1` for the same reason the read side does.
- **`GroupLive.Results` gained a "Get the share link again →" link, `:voting` only.** `/` routes a `:voting` group to `/groups/:id/results`; `04 share` was otherwise reachable only from `03 review`, and `03 review` only from `04 share`'s `‹`. The two were a closed island, so an organizer who closed the tab could never re-copy the link this product exists to hand out — while the chrome made the screen *look* fully navigable. It sits directly above "Nudge N friends", which is the button whose flash tells you to share the link again.
- **The `Create your own →` pill carries a `data-confirm` on `/join/:slug/vote` once anything is selected** (`pill_confirm`, passed by `JoinLive.Ballot`, `nil` on an empty ballot and on the other two `/join` screens). Ruling 8 settles that the pill is present and it stays; it does not settle that the loudest control on the ballot — ink border and `shadow-sticker-2`, against a disabled peach "Send my votes" — may discard an unsent ballot on one reflexive tap, on the screen the "guest drop-off under 5%" metric is measured on.
- **`AdminLive.Users` no longer uses `<.table>`.** The five-column table measured 678px inside a 372px `overflow-x-auto` box, so Promote, Demote and Delete — the three controls that screen exists for — were entirely off-screen, announced by a 4px scrollbar stub. This is not a breakpoint problem: `Layouts.app`'s `:phone` column is 440px and that is every width this screen has, so the table could never fit. One `sticker_card` per account instead — identity and role pills, the email, a `Joined … · confirmed` line, then the actions on their own wrapping row. `CoreComponents.table/1` stays for a future `width={:wide}` screen and currently has no caller.
- **`404` and `500` wear the chrome.** `ConsensusWeb.ErrorHTML` now embeds two templates rendering `Layouts.app` with `variant={:marketing}` — the only correct variant, since an unmatched path raises before any pipeline runs and there is no `current_scope` to read. A mistyped `/join/<slug>` is the likeliest 404 this product has, and the generator's answer was the unstyled words "Not Found" with no link anywhere: the same dead end, on the one surface P1's sweep could not reach because it is not a LiveView. `render_errors` in `config/config.exs` gained `root_layout: {ConsensusWeb.Layouts, :root}`; without it the templates render as a fragment with no `<head>` and therefore no stylesheet.
- Two smaller sweeps of the same "two controls, one meaning" rule: `/feedback`'s forward action is now the tangerine `<.button>` its three sibling standing pages carry, instead of a `text-ink-soft` caption-shaped link alone in whitespace; `/how-it-works` lost its body-level "About us", which sat ~90px above the footer's own "About us"; and `02b`'s photo control is "Remove photo", so the bare word "Remove" belongs only to the one that deletes the option.
- **A real, shipped crash was fixed inside this change and it was not a chrome bug.** `ConsensusWeb.HomeLive` had no `handle_info/2` head for `{:participant_joined, _}` or `{:ballot_cast, _}`, which `Consensus.Voting` broadcasts on the *same* `Activities.topic/1` `HomeLive` subscribes to (`voting.ex:154`/`:359` publish; `home_live.ex` subscribes with `Activities.subscribe_group/1`). An organizer sitting on `/` lost their LiveView the moment anyone joined or voted — a product-invariant-4 failure introduced with the voting loop (D-034…D-037) and found in the browser while verifying this chrome. Two clauses were added, both a plain `refresh_groups/1` because a ballot can complete a group and move it between the active and past lists, and pinned by "survives the voting broadcasts that share the group's topic" in `home_live_test.exs`. Recorded here so an audit of the voting loop learns it ever crashed.
- **The footer drops the whole mood pair on `/feedback`, and `return_to` grew a general self-link guard.** On `/feedback?mood=happy` the happy face emitted `href="/feedback?mood=happy&return_to=%2Ffeedback%3Fmood%3Dhappy"` — a link to the page being rendered, whose `‹` then pointed at a byte-identical screen, so the real way out was two presses away with nothing saying so. ~~The pair cannot simply be dropped the way a standing link is (the *other* mood is a real destination), so the face for the mood you are already looking at renders as **inert text** with `aria-current="page"` and no `press-2`.~~ **History — that half was wrong and lasted one round.** Rendering the current face inert fixed the self-link and left the worse defect untouched: the *other* face is a `live_redirect`, so one reflexive tap remounted `FeedbackLive` and silently destroyed whatever the visitor had typed, with no confirm and no undo (measured: 23 keystrokes into the message, one tap, an empty textarea). And the two controls disagreed — the footer reads the mood out of the URL while the form's own picker changes it without navigating, so using the form's picker left the footer announcing `aria-current="page"` on the mood the form no longer held. `/feedback` already carries this control: a 44×44 two-state radio group captioned "tap to switch" (frame `00c`). So `show_mood_pair?/2` drops the pair there outright, the way `standing_links/1` has always dropped the link for the page it is standing on and `:public` drops the pair for the whole `/join` tree, and `mood_face/1` is back to one branch with no inert state anywhere in the app. `FeedbackLive`'s own moduledoc asked for this fix by name. What survives from the first cut is the general guard: `Chrome`'s `return_to_for/2` refuses to append a `return_to` whose path equals the link's own path, which is what stops the footer's `Privacy` link on `/about?return_to=/privacy` offering a `‹` back to the screen you just left — pinned by "a link never inherits a return_to that points at itself", which is the only test that reaches that clause. `/feedback` is additionally never nominated as an origin — it is the one standing page that is a form, and returning somebody to a form they already navigated away from returns them to an empty form, so a visitor who reached it from step 2 of the wizard keeps step 2 (the inbound `return_to` is passed through, as before) and one who opened it cold has no origin and the standing links fall back to `/`.
- **The chrome's link hovers are `hover:text-tangerine`, not `hover:underline`.** Frames `00a` and `4a` carry `style-hover="color:#FF6A2B"` on the three standing links, the `marketfinder.us` credit and the `:marketing` log-in link, and the underline was the one place in this chrome a reader could tell the frame from the app. This does not spend the screen's one tangerine: that rule is about a *resting* forward action, and the `:public` pill already goes tangerine on hover for exactly the same reason. `hover:bg-yellow` stays on the two 29px circles, which is what the frames draw.
- **The wordmark is 19px/13px on `:app` and `:marketing`, and 18px/12.5px only on `:public`.** It shipped keyed on `:app` alone, so `/` — one route with two variants — grew its own wordmark by 1px the moment you signed in, i.e. the bar changed size under a visitor who had done nothing to it. `:marketing` and `:app` are the same five routes seen signed out and signed in and must draw it identically; frame `00a`, which ruling 3 cites for the marketing header, draws 19/13 like `4a`. Only ruling 2's `/join` header (frame `1c`) is the smaller pair.
- **The `⋯` drops Settings *and* Admin while a signed-in visitor is standing on `/users/log-in`.** That combination happens in exactly one situation: an expired sudo window, which `UserAuth`'s `:require_sudo_mode` hook bounces to the log-in form. `on_path?/2` was comparing against `/users/settings` while the rendered path was `/users/log-in`, so the menu kept offering Settings — and tapping it bounced straight back to the identical screen with the identical flash, a two-tap loop with no signal that it was one. Admin goes with it: it does not loop (an administrator may *read* `/admin/users` without sudo) but it is the other half of the same trap, and offering a way to leave the screen that exists to collect the credential is offering a way to abandon the task. The email line and Log out stay, so the menu still earns its place.
- **The `:marketing` log-in link is padded to a 44px minimum hit area.** (It was labelled `Sign in` here and until D-048; the padding is unchanged.) Bare 600/11.5 text with no border or background measured ~40×17px, in the top-right corner of a phone. It keeps the frame's visual treatment exactly — `-my-2` cancels the vertical padding so the anchor's *margin box* stays 28px, the 48px header does not grow, and the text does not move. Frame fidelity and a touch target are not in tension here; a static mock simply cannot surface the second one.
- **Every other control in the chrome got the same treatment, and the arithmetic has one trap worth writing down.** The two 29px header circles (`#chrome-back`, the `⋯` `<summary>`) and the `:public` `Create your own →` pill all measured under 44px and all three keep their painted size — frame `4a`'s header is a constant 48px and a 44px circle does not fit inside it — so each grows a transparent `::before` instead. **The inset is measured off the *padding* box, not the border box.** An absolutely positioned pseudo-element's containing block is its parent's padding box, and everything here is `box-sizing: border-box` with `border-2`, so a 29px circle grows from 25px and a 27.8px pill from 23.8px. `before:-inset-[7.5px]` shipped once with a comment asserting `29 + 7.5 + 7.5 = 44` and measured **40×40** in the browser — a 4px error inside the fix whose entire purpose was that number, caught by two critics and by nothing in the suite. It is `-inset-[9.5px]` (25 + 19 = 44) and `-inset-y-[10.5px]` (23.8 + 21 = 44.8) now, verified with `getComputedStyle(el, '::before')` and an `elementFromPoint` sweep, and pinned by "both circles have a 44px hit area and acknowledge a tap" and "the pill has a 44px hit area" in `chrome_test.exs` — there was no assertion of any kind on either before, so deleting the expansion outright left the suite green. The circles additionally gained `active:bg-yellow`: hover does not exist on touch, so tapping Back or the `⋯` on a phone acknowledged nothing at all, and yellow is the colour frame `4b` already hovers them to. They are deliberately **not** `press-2` / `shadow-sticker-2` — every 29px header circle in `4a` and `4b` is a 2px ink border with no `box-shadow`, and `press-2`'s hover rule *adds* `--shadow-sticker-1`, so the circle would grow a shadow on hover and lose it on press.
- **The footer's four rows are the screen frames' geometry except for the container's row gap, which is 8px rather than the frame's 2px, on purpose.** `IMPORT-NOTES.md` §4.2's other numbers are all taken (26px faces, 15px glyph, 8px pair gutter, 10.5px label, `7px 14px 9px` padding). The gap is not, because the three text rows carry 26px hit boxes built from `min-h` plus a cancelling negative margin, and two stacked rows built that way overlap by exactly `2 × margin − gap`: at `-my-1` and an 8px gap that is 0, and at a 2px gap it would be 6px of every standing link owned by the *outbound* `marketfinder.us` link beneath it (later in DOM order wins `elementFromPoint`) — which is the defect an earlier cut at `-my-1.5 min-h-[30px]` actually shipped and a critic measured. The frame's rhythm and a 24px touch target are mutually exclusive for a 10.5px text row; the touch target wins and the cost is stated here. Measured at 420×900: the footer is 120.25px against the frame's 97px, of which 18px is the three widened row gaps. The header is 48.00px, so the chrome costs **168px** of a 760px phone viewport — 22%. That figure has now been wrong twice in this entry (`167px`, then a `163px` that did not equal its own stated 48 + 120), so treat 168 as the one number and grep for the other two before adding a third.
  - **The row gap is the only gap that is load-bearing; the *column* gap in the link row was tuned wrong and is fixed.** `gap-x-3` (12px) plus `px-1` on each link put 16px between "About us" and the `·` where `IMPORT-NOTES.md` §4.3 transcribes `gap:8px`, so the row measured 218px against the frame's 178px and the dots floated mid-gap instead of binding three labels into one phrase. The comment justified the widening as WCAG 2.5.8, which does not survive the `min-h-[26px]` on the same element — two flex siblings in a row cannot overlap however small the gutter is, so the extra width bought no touch safety at all. `gap-x-2`, no `px-1`; the vertical set (`-my-1 py-1 min-h-[26px]` against the container's `gap-2`) is untouched and still the thing not to tune alone.
  - **The three standing links stay 26px tall, which is a stated deviation from p1-cleanup §9b's "pad them the way section 7 pads `Sign in`" (the header link D-048 relabelled `Log in`).** They clear WCAG 2.5.8 AA's 24px floor and miss the 44px platform minimum, and there is no cheap fix: the row pitch *is* 26px, so any 44px box overlaps its neighbour by 18px whatever technique builds it, and closing it costs ~30px more footer on top of the 23px already spent. Not "padded the way the header's log-in link is" — say 26px.
  - **The two 26px feedback faces went from a measured 27×27 hit box to 30 wide × 37 tall, and 44px is not reachable here.** ~~Sideways, 4px is exactly half the 8px gutter.~~ **Amended by D-047: the box is 39 wide (`-inset-x-2`) against a 24px gutter (`gap-6` on the pair's own wrapper), leaving 11px of dead space between them** — measured with an `elementFromPoint` sweep, not derived; the `38`/`8px` this line and D-047 both carried at first were the arithmetic. The reasoning is unchanged and is why the amendment was needed — these two mean *opposite* things, so an overlapping pair would file the wrong mood on a near-miss, which is worse than a small target (swept with `elementFromPoint`: zero points resolve to both faces) — but at the frame's 8px gutter the largest non-overlapping box left the two *touching*, i.e. about a pixel of clearance between "this is going well" and "this is broken". Widening the gutter bought both a bigger box and real clearance; nothing painted moved. Upwards, 9px is exactly the footer's `border-t-2` + `pt-[7px]`; one pixel more and a positioned pseudo-element starts winning taps on the screen's last line of content. Downwards, 6px is where the standing-link row's box begins — **at the 11px that would have made the box 44px tall, all three standing links lost 3px and `Privacy` measured 23px, under WCAG 2.5.8 AA's 24px floor**, because a positioned pseudo-element beats a static sibling whatever the DOM order says. Reaching 44 therefore costs either a neighbour under the AA floor or ~3px more of an already over-budget footer, and neither is worth it. Nothing painted moves: 26px face, 15px glyph and 120.25px footer all unchanged (the 8px gutter between the two faces became 24px in D-047, which is the one painted number that did move).
  - **The five text links in this chrome gained `active:text-tangerine` beside their `hover:`.** Hover does not exist on touch — the same gap `active:bg-yellow` closed on the two circles — so `About us`, `How it works`, `Privacy`, the `marketfinder.us` credit and the `:marketing` log-in link acknowledged a tap on a phone in no way at all. Same colour the hover already uses; nothing is invented.
- **`README.md`'s route table gained `/about`, `/how-it-works`, `/privacy` and `/feedback`.** All four shipped with this entry and none was added to a table that otherwise enumerates every route down to `/dev/mailbox` and `/health` — the doc-propagation failure CLAUDE.md names as this repo's own. `.gitignore` gained `__pycache__/` and `*.pyc` in the same pass, because `docs/design/extract_screens.py` leaves one beside itself on every re-import.
- **The two reconnect banners say different things because they mean different things, and the `500` page points at a face it can actually see.** `#client-error` fires on `phx-disconnected` — the socket is gone — and says "Lost the connection". `#server-error` fires when the server *answers* and rejects or errors the join, which is a crashed LiveView far more often than a network fault; it shipped as "The connection dropped", i.e. the same invented cause the generator's "We can't find the internet" was replaced for, and in copy interchangeable with its sibling. It says "This page hit an error" now. Separately, `500.html.heex` told the reader to use "the unhappy face at the bottom of any page" — untrue since this entry, because `show_mood_pair?/2` drops the pair on `:public` (the whole `/join` tree) and on `/feedback`. It points at the face on *this* page instead ("in the footer below"), which the `500` template renders itself with `variant={:marketing}` and cannot go stale.
- **Every dimension in this chrome — and in this app — is a *border-box total*, and the frames are content-box.** The design frames are standalone inline-styled HTML whose only `<style>` block touches `body`: no reset, so a frame's `width:29px; border:2px solid #17211C` paints **33px**, and its 26px face paints 30px. Tailwind's preflight sets `box-sizing: border-box`, so the same declaration written `size-[29px] border-2` paints 29px. This app reads every such pair as the painted total and was therefore uniformly 4px tighter than the frames render, on the header circles, the footer faces, the body's cards and the chips alike. That reading is not new here — `IMPORT-NOTES.md` §3.1 derives the header's 48px height from exactly this arithmetic (`29 + 8 + 9 + 2`, which is border-box arithmetic performed on a content-box frame) and the whole design system was imported under it. It is written down because it had been decided by CSS reset rather than by anybody.

  ~~**Do not "correct" one control to the size its frame paints.** If the whole system is ever re-cut to the frames' painted sizes, that is a new entry, not a fix.~~ **Amended by D-046 and D-047, which re-cut four controls and left this sentence standing above them — the shipped UI followed both rules at once for a whole review round, on the single most repeated question in the design import.** The blanket prohibition was written to stop a *cosmetic* correction, and that part still holds: uniformity is worth more than any single control's fidelity, and 4px on its own is never a reason to move something. What it did not anticipate is a control where the 4px costs something a reader can feel, and four of those turned up:

  | Control | Was | Now | Why it moved |
  |---|---|---|---|
  | `1c-0`'s deck Pass / Veto / Pick | 58 / 44 / 58 | 62 / 48 / 62 (D-046) | the veto square sat *on* the 44px touch floor with no margin, on the ballot |
  | `00b`'s numbered step badge | 32 | 36 (D-046) | repeated four times; it is what carries the timeline's rhythm |
  | `00c`'s message textarea | 110 | 138 (D-046) | the screen's one required field, ~1.5 lines shorter than drawn |
  | `00c`'s form mood pair | 36 | 40 (D-047) | no container depends on it; the 48px label owns the touch target either way |

  **The standing rule, replacing the prohibition.** The border-box reading is still the default and still what an unstated control gets. It is *binding* wherever a frame states a **container** dimension that the control's painted size feeds: `IMPORT-NOTES.md` §3.1's 48px header is `29 + 8 + 9 + 2`, so a 33px `‹` makes the frame contradict itself at 52px, and §4.2's 97px footer is a set with its 26px faces (this app is already 23px over it). Those two are the reason the chrome's circles and the footer's faces stay at 29 and 26 and are **not** an oversight — both already carry expanded hit boxes, so the 4px buys nothing there either. Everywhere else, if the 4px costs a touch target, a line of a text field, or the rhythm of a repeated element, re-cut it to the frame's painted total and say so in the entry that does it. `chrome.ex`'s moduledoc carries the same rule; keep the two in step.
- **The `⋯` is universal on `:app`, which overrides `IMPORT-NOTES.md` §3.2's `00b`/`00c` rows.** That table — declared exhaustive — gives `00b` how it works and `00c` feedback "**no `⋯`**", and §3.5 leans on the omission as its only positive evidence that the menu is account-scoped. Signed **out**, this app matches the frames exactly: `/how-it-works` and `/feedback` render `:marketing`, which has no `⋯` at all. Signed in they render `:app` and keep it, deliberately: ruling 4 settles the menu's contents as account-shaped, a signed-in visitor on a standing page still needs Log out and Settings, and the rule cannot be applied per-frame anyway — `/about` and `/privacy` are undrawn (ruling 7), so honouring §3.2 literally would drop the menu on two of the four standing pages and keep it on the other two for no reason a user could see. Consistency across the four wins; the table's rows are read as the signed-out state.
- **`Chrome.footer/1` takes a `confirm`, and `Layouts.app/1` a `footer_confirm`, because every control in that bar is a `navigate`.** From a screen holding text nobody has saved, one tap on a mood face or a standing link remounts the LiveView and the typing is gone with no confirm and no undo — measured on `/users/register` (all three fields), `/groups/new` (the title), the `02b` option editor (a 47-character description) and `/feedback` itself (96 characters) — and the `?return_to=` then brings the visitor back to an *emptied* form, which is what makes the round trip read as safe. `show_mood_pair?/2` had already closed the `/feedback`-to-`/feedback` case and `pill_confirm` had closed the ballot's; this is the same escape hatch generalised to the rest of the bar. ~~**The mechanism ships; the four call sites do not yet pass it.**~~ **History — closed by D-045**, which wired it on **six** screens (the four named here plus `user_live/settings.ex` and `admin_live/feedback.ex`) and added the missing third member of the set, `back_confirm`, because the header `‹` is a `navigate` too and is the control *nearer* the form. `Chrome.header/1` takes `back_confirm`; `Layouts.app/1` passes it. A screen that guards the footer and not the `‹` has plugged the far door and left the near one open.
- **On a page reached *from* `/feedback`, the `‹` and the device's Back gesture go to different places, and that is the accepted side of a trade.** `/feedback` is deliberately never nominated as an origin (`inherited_return_to/1`), so from `/feedback?mood=sad&return_to=%2Fgroups%2F19%2Foptions` a tap on `About us` lands on `/about?return_to=%2Fgroups%2F19%2Foptions`, whose `‹` goes to the wizard step while `history.back()` goes back to `/feedback`. Two disagreeing back affordances is plan ruling 1's own objection with the OS gesture standing in for the second control. The alternative is worse in the direction that matters: making `/feedback` an origin points the `‹` at a form the visitor already abandoned and which comes back empty — a control that appears to restore work and does not.
- **Ruling 8 is applied to the whole `/join` tree, not only to the ballot, and the cost is real.** A critic argued the standing links should return on `/join/:slug` and `/join/:slug/results`, where nothing is unsent — and the sharpest version of that is true: the entry screen is the one place in this product where an account-less stranger is asked for a name, and it is the one place with no route to `/privacy`. Ruling 8 says "the `/join` tree gets the footer's credits and nothing else" and it is settled, so the footer keeps its shape. The gap belongs to `JoinLive.Entry`'s body, which can carry a Privacy link under the name field without putting five `navigate`s on the ballot two screens later.
- Regression guard: [test/consensus_web/components/chrome_test.exs](../test/consensus_web/components/chrome_test.exs) pins all three variants, the back control's presence and absence, the `⋯` menu's three states, both feedback moods, and that the four new routes render rather than 404. **Its second half is route-level and is the half that matters**: a table walks every screen in the app and asserts the variant and the `back` each one actually *passes* to `Layouts.app/1`. The component tests alone left a real hole — deleting `variant={:public}` from `join_live/ballot.ex` grew a guest's ballot a `⋯` menu offering Log in / Start something (`Get started` at the time), and deleting `back` from `admin_live/users.ex` or `user_live/settings.ex` returned those screens to having no way out, with the whole suite still green. **One of its own assertions was vacuous and is now per-control**: "both circles have a 44px hit area and acknowledge a tap" counted `active:bg-yellow` across the whole fragment, which the `⋯` menu's two entries already satisfy through `menu_item_class/0` — stripping the class from *both* circles left the file green under mutation. It splits on `circle_hit_area/0` and reads each circle's own class attribute now. That is the second time this one test has been the thing standing between a 4px/no-feedback regression and a green suite; assert per control here, never app-wide.
- **The header's horizontal padding is 13px only when it opens with a circle.** `IMPORT-NOTES.md` §3.2's variant table gives `6px 13px 8px` / `8px 13px 9px` to every header with a 29px `‹` and `6px 20px 8px` / `8px 20px 10px` to the two that have none (`00a` splash, `00` home signed in), with the `1c` public header at 14px. 13px is where a *circle* sits so its glyph lines up with the body's 20px page gutter; applied to a header with no circle it hangs the wordmark 7px left of every card below it, which is the one place the bar visibly leaves the content grid — and it did that on `/`, the app's most-visited screen, signed in and signed out. `header_padding_x/1` picks 13/14/20 and the 48px height is unaffected.

---

## D-042 — Feedback is a public, actorless write with a first-class thank-you screen

- **Date:** 2026-08-09
- **Status:** settled

`Consensus.Feedback` ([lib/consensus/feedback.ex](../lib/consensus/feedback.ex)) and one table, `feedback`, behind design frame `00c` at `/feedback` ([`ConsensusWeb.FeedbackLive`](../lib/consensus_web/live/feedback_live.ex)). D-041 put the two faces in `ConsensusWeb.Chrome.footer/1` on every screen and pointed them at a stub that stored nothing; this is the write path they were always asking for.

**The write path takes no actor at all.** The footer is on every screen this app renders, including screens a signed-out stranger reaches from a shared link, so `submit/2` is shaped like `Consensus.Voting.create_participant/2` and *not* like `Consensus.Activities`, which proves ownership by binding a scope's `user_id` and a row's `organizer_id` to the same variable in the function head. There is nothing here to own. Being a public unauthenticated write, it **rescues `[Exqlite.Error, DBConnection.ConnectionError]` into `{:error, {:database_busy, message}}`**, copied verbatim from `create_participant/2` (invariant 17). It deliberately does **not** retry the way `cast_ballot/3` does: a ballot has a deadline that makes a whole group press submit at the same instant, and feedback has no stampede to absorb. One refusal, one honest error on screen naming the fix ("press Send feedback again"), and the sender's typing still in the form.

**What is captured, and what deliberately is not.** Mood (`happy`/`sad`, an `Ecto.Enum` over a plain `:string` column — never a database `CHECK`, which SQLite only accepts inside `CREATE TABLE`), the message, an optional name and email, `user_id` when the sender happens to be signed in, and `page_path` — **only** while the form's default-on "include the screen I was on" box stays ticked. Nothing else: no user agent, no IP, no referrer. A default-on checkbox whose write path ignores it is a lie, so the decision lives in the changeset (`Entry.put_page_path/2`) rather than in the LiveView, and the test that proves it is a context test.

**The row shows a route-derived label *and* the literal path, not the frame's `(Dinner Friday? · voting)`.** Resolving a session title out of `/groups/12/review` means reading a group from a path any visitor can type, so `/feedback?return_to=/groups/7/review` would print a stranger's session title onto a signed-out page. ~~The path alone is therefore what the row shows.~~ **History — corrected in review.** The path alone was frequently unreadable to the person being asked to consent to it: the footer's faces are tapped from the home page more than anywhere else, and there the entire evidence was the single character `/` floating in a dashed box. `FeedbackLive.page_label/1` maps the *shape* of the path to a name — "Home", "Adding options", "Reviewing the pool" — with no query and no database read, so it leaks nothing that resolving a title would, and the row reads `Include the screen I was on (Home)` with the literal path as a small mono line beneath. The label is a description; the path is what actually gets stored, so both are shown.

**`page_path` is refused unless it is a plain local path, and the guard is in the changeset.** `Entry.safe_page_path/1` rejects anything not starting with a single `/`, and anything containing whitespace, a C0/C1 control character or a backslash. `ConsensusWeb.CurrentPath.safe_return_to/1` is **not** sufficient on its own: it rejects a literal `//` and `/\` prefix, but an ASCII tab between the two slashes survives it, and the WHATWG URL parser strips tab/LF/CR from a URL before resolving it — so `/\t/evil.example/x` resolves as `//evil.example/x`, off-site. This is the one column here written from a query parameter *and* later rendered as an `href` on `/admin/feedback`, so without the guard an unauthenticated stranger could plant an off-site link on a control an administrator is invited to click. It is applied on the way in (the changeset), on the way to the public form, and again at render time on the admin queue. `"/"` is deliberately still accepted — a `\A/[^/\\]` shape check would drop the commonest captured path of all. The four standing pages in this piece also filter the header's `‹` through it, because `back` built from the raw parameter is the same open redirect; the durable one-line fix belongs in `safe_return_to/1` itself.

**`user_id` is `ON DELETE SET NULL` and there is no `group_id` at all.** Deleting an account through `/admin/users` must not destroy the bug report that account filed, and recording the session as a path string rather than a reference keeps a report alive after its group is deleted — and keeps invariant 5's cascade paragraph from growing a fourth level.

**Sending replaces the form with a full-page thank-you, on the same route, and `push_patch`es to `?sent=1`.** This is the premise of `docs/plans/chrome-and-feedback.md`: a flash strip over a screen that still looks like the form reads as "nothing happened". A separate `/feedback/sent` **route** is still rejected — it is a URL somebody can bookmark and return to, thanking them for nothing. ~~The state therefore lives only in socket assigns.~~ **History — corrected in review.** Assigns-only meant the URL never changed, so a reload, or the browser Back button after tapping "Back to what you were doing", dropped the sender onto an empty form with no evidence anything had been sent: the same "reads as nothing happened" failure, displaced by one action, and a review walk that did exactly that left three near-duplicate rows in the table. The thank-you now patches to `?sent=1`, so the state is where a reload can find it.

**And it patches with `replace: true`, which a second review round found was still missing.** `?sent=1` fixed the reload; it did not fix Back. Without `replace`, the pre-submit URL stayed in history *underneath* the thank-you, so one press of the browser Back button — the most natural gesture on a phone, on a screen whose only other control is a forward button — popped back to a form still holding every word the sender had typed, with a live tangerine **Send feedback** and nothing anywhere saying it had already gone. Walked in a browser: two byte-identical rows 35 seconds apart. Replacing the entry means Back leaves `/feedback` for the screen the face was tapped on, which is where the thank-you's own button goes anyway. `handle_params/3` additionally keeps `sent?` true whenever the process still holds the row it wrote, so no popstate can resurrect a form for a submission already made.

A **cold** visit to `?sent=1` (a bookmark, a typed URL, a restored tab) still renders a thank-you, because a reload after a real send is indistinguishable from it. But it must not *assert a stored record*: both "Your note is saved." and the "included the screen you were on" line are gated on the row this process wrote, and without one the card says only what is true of feedback in general, plus a link to the blank form. That gating is the whole reason the parameter is a flag and not `?sent=<id>`: an id would mean reading a stranger's entry, and printing their `page_path`, on an unauthenticated page. The thank-you states what was stored, says whether the screen was included, and **does not promise a reply the app cannot deliver** — there is no outbound mail path for feedback, so it says that nothing was emailed and that any reply would be a person writing back by hand. The email field's helper says the same thing before the send.

**Frame `00c`'s `Cancel` is not built.** Plan ruling 1 is explicit that a form's Cancel resolving to the same route as the header's `‹` is the duplicate back affordance this work removes, and this one would: both go to `return_to`. The action bar is the one tangerine **Send feedback**. On the thank-you state the trade runs the other way — the body carries the way back, so `Layouts.app`'s `back` is passed `nil` there and the header draws no circle.

**The action bar is pinned, as IMPORT-NOTES §6.5 specifies.** ~~It is `mt-auto` in the column's ordinary flow, because a nested scroller under a sticky header is the one thing a phone handles badly.~~ **History — corrected in review.** That argument was true about *nested scrollers* and §6.5 does not ask for one. In flow, the screen's single forward action measured 84px below the fold at the frame's own 420×700 and 159px below it at 360×640, on a screen with no Cancel. It is now `sticky bottom-0`, which needs no nested scroller and costs nothing here because `Chrome.footer/1` is deliberately **not** sticky (D-041): measured at the bottom of the scroll, the bar ends at 615.6 and the footer begins at 615.6, so there is never a second pinned surface competing for the edge. **Pinning it has two costs this entry did not pay, and D-046 pays them:** the scroll body must reserve the bar's height (an opaque pinned bar over a body with no reserve simply deletes that much live content — 16.4px of a 110px textarea visible at 360×640, and focusing it does not scroll), and the capture-consent row has to move *into* the bar, because a `sticky` Send is reachable without scrolling and a consent row in the body can therefore be skipped unseen.

**`00b`'s copy is rewritten because three of its sentences are false here.** `/how-it-works` keeps frame `00b`'s structure, rhythm and four-beat timeline and replaces the words. The frame promises *"Anyone you invite can throw theirs in too"* (friends adding options is Post-MVP and the pool freezes when voting opens — invariant 16 / D-037), *"Drag your top three"* (the ballot is approval voting with veto elimination — D-034), and *"Change your ranking any time before the timer ends"* (a cast ballot is locked — D-036). The two irreversible facts the frame denied are stated instead, in the "Good to know" card. Recorded in `docs/design/DESIGN-SPEC.md` under `00b` the way `00a`'s substitution is, and pinned by `refute` assertions in [test/consensus_web/live/how_it_works_live_test.exs](../test/consensus_web/live/how_it_works_live_test.exs).

**Spam and abuse posture, stated because the plan asks for it: there is none, on purpose.** No rate limit, no CAPTCHA, no honeypot, no moderation queue in front of the write. This is a single-machine SQLite app with no public traffic, the row is inert (it renders only inside `/admin/feedback`, never on a public page, so there is nothing to inject *into*), and every mitigation worth having is either a friction tax on the one channel the product has for hearing that it is broken (CAPTCHA — also a bot check, which this repo will not ask a user to solve) or a dependency this deployment does not have (a shared rate-limit store). **The trigger for revisiting is a flood in `/admin/feedback`**, and the cheapest first answer is a per-IP token bucket in the endpoint, not a CAPTCHA.

**And the recovery lever that posture leans on is deliberately not in the app: there is no delete on the queue.** `/admin/feedback` marks read and annotates, nothing more, and `list_entries/0` is unbounded. Deleting a spam run is `sqlite3 $DATABASE_PATH 'delete from feedback where …'` by hand — recorded here so the omission reads as a decision rather than an oversight. A delete button is the obvious first thing to build alongside the rate limit when the trigger above fires; it was left out now because a destructive control with no undo, on a screen whose whole argument for having no sudo gate is that everything on it is reversible in one click, is a worse trade than a manual `DELETE` on the day it is first needed.

**Consequences:**
- `mood` is required. It is one tap of two 44px targets, it is the cheapest signal in the record, and frame `4a`'s whole argument for the pair is that "one tap already tells you the sentiment". A direct visit to `/feedback` with no `?mood=` renders both faces unpicked and the changeset refuses with "tap a face so we know which way this went" rather than storing a blank.
- The mood is a **two-state radio group**, not a toggle: frame `00c`'s caption is "From the footer — tap to switch", so the footer's face is a default the sender can correct. The 36px circle the frame draws sits inside a 44px `<label>`, so the tap target clears the phone minimum without the circle growing.
- `message` follows invariant 11 / D-026: **no `maxlength` attribute**, `Entry.max_message_length/0` (600) enforced in the changeset, and a live grapheme counter reading that same function and turning tangerine past it.
- The four standing pages moved from `bg-canvas` to the default `bg-surface`. Frames `00b` and `00c` both specify `#F7FBF8`; `/about` and `/privacy` have no frame and follow their two siblings.
- `/privacy` now names the one third-party request this app actually makes — `root.html.heex` loads Instrument Sans and DM Mono from Google Fonts. There is no analytics, tracking or error-reporting dependency in `mix.exs` and no tracker in `assets/` (grepped), but "no third parties" while the browser calls out for two typefaces would have been false.
- [test/consensus/release_test.exs](../test/consensus/release_test.exs)' `rollback/2` test asserts against the **newest** migration by name, which is now `create_feedback`. It was asserting the voting tables disappeared; those are now in its "still there" list. Any future migration inherits the same edit.
- **A signed-in sender cannot decline `user_id`, and both the form and `/privacy` now say so.** `FeedbackLive` passes `user_id:` unconditionally and `Entry.sender_label/1` falls back to the account's username, so the email helper's "leave it blank to stay anonymous" was a promise the write path cannot keep for them — it is now shown only to a signed-out visitor, where it is exactly true, and a signed-in one is told the message arrives under their account. `/privacy`'s "If you send feedback" section enumerates the columns and closes with "Nothing else", which is a closed list, so it names the account too.
- **`/about` and `/admin/feedback` say "the two faces in the footer", not "every screen".** `Chrome.footer/1` gates the pair on `variant != :public` and the whole `/join` tree is `:public` (D-041), so a guest mid-ballot has no faces at all. The admin summary states the gap outright, because an operator who believes the queue covers the voting funnel reads silence from voters as "no problems".
- The comment introducing the route in `router.ex` deliberately does not contain the admin scope's own path literal: `router_test.exs` finds the admin scopes by scanning the router source for it, and a mention inside a comment is indistinguishable from a scope that pipes through nothing. It cost a red suite once.

---

## D-043 — The feedback queue is admin-only by function head, with no sudo gate and no notifications

- **Date:** 2026-08-09
- **Status:** settled

`ConsensusWeb.AdminLive.Feedback` at `/admin/feedback`, in the **existing** `scope "/admin"` and the **existing** `live_session :require_admin` — a `live_session` name is declared once — so it inherits both guards without restating either: the `:require_admin_user` plug rejects the HTTP request and the `:require_admin` on_mount hook rejects the websocket mount, because a plug pipeline does not run for the socket connection (invariant 1). `router_test.exs` walks every `/admin` route and now names this one explicitly.

**The context's two admin writes are authorized by the function head.** `Consensus.Feedback.set_read/3` and `annotate/3` take the actor's `%Scope{}` first and match `%Scope{user: %User{is_admin: true}}` in the head, so a non-admin caller raises `FunctionClauseError` rather than being refused at runtime. Invariant 1 describes that as "the right shape for a *non-destructive* admin-only write if one is ever added — precondition, not runtime branch", and notes it has had **no living example** since `Consensus.Content.update_home_page/2` was deleted with the home page (D-027). These two are that example. Neither re-reads the actor inside a transaction, which the destructive writes in `Consensus.Accounts` do, because neither is destructive: the worst a stale admin tab can do here is mark a message read, which any admin undoes in one click.

**No sudo-mode gate, deliberately.** Sudo (D-021) protects `Accounts.set_admin/3` and `delete_user/2` — account takeover and irreversible deletion. Marking a message read and typing a note beside it are recoverable in one click and change nothing outside their own row. Putting them behind a re-authentication prompt would train administrators to type their password to triage a bug report, which is exactly how a real sudo prompt stops being read. Recorded here so the omission reads as a decision.

**Nothing on this screen notifies anybody, and the screen says so.** No mail, no webhook, no state change beyond the row. `Consensus.Feedback.annotate/3`'s note is private to administrators and inert, and it is said in the UI rather than only in a comment, because an administrator typing "replied to them" needs to know the app did not. It is said **twice, in two places, once each**: the page summary carries "nobody is emailed either way" once, and an open note editor carries "Private to admins. Saving emails nobody." ~~The note field's helper line reads "Only administrators see this. Saving it emails nobody and changes nothing else."~~ **History — corrected in review:** that sentence rendered beside *every* row, so a fifteen-message queue said it fifteen times. The save flash says "Nobody was emailed" for the same reason.

**The note editor is collapsed until it is wanted, and `open` is server state.** Rendering every row's textarea, counter, helper and Save button unconditionally cost 460px a row — 11 viewport heights for 15 messages at 360×640, 44% of the card area an empty textarea — on the one screen whose entire job is scanning. A closed row is mood, sender, message, metadata and two buttons, measured at 225–244px. The toggle's label carries the note's length when there is one (`Note · 41 characters`), so a closed row still says whether anything was written on it, and a row that already carries a note is seeded open at mount because the note is the record of what was done.

It is **not** a `<details>` element, although that is the no-JS idiom the header's `⋯` menu uses. `open` on a `<details>` is an attribute the server also renders, and every row lives inside a `:for` comprehension that re-renders whenever `:note_forms` changes — which is on every keystroke, because the grapheme counter is server-rendered. The patch would reset the attribute and collapse the editor under the admin's hands as they typed. `:open_notes` is a `MapSet` of ids in assigns instead, seeded **once** and then owned by the administrator's own toggles: re-deriving it on every event would spring a deliberately-collapsed row back open on the next keystroke anywhere on the page.

**Both admin writes rescue SQLite, the same way `submit/2` does.** Invariant 17's letter binds public unauthenticated writes, so this is a gap rather than a violation of it — but SQLite *raises* rather than returning a tuple when a write cannot take the lock, and a raise walks straight past the `with/else` in this module's friendly catch-all. A busy database would crash the admin's LiveView and take every unsaved note on the page with it, which is precisely what `load_entries/2` exists to prevent. Both `{:error, {:database_busy, _}}` branches flash and reload **nothing**.

**The captured screen opens in a new tab.** It was a same-tab `href`; followed, it stranded the administrator (the destination's `‹` goes to `/`, not back to the queue) and unloading the page discarded every note being typed on it — measured, 56 characters gone. `target="_blank" rel="noopener"`, labelled "(opens a new tab)" so the outcome is predictable before the tap. A `data-confirm` would not have helped: the note is lost either way if they proceed.

**Mark-as-read is reversible from the same button.** `read_at` is a nullable timestamp the way `participants.voted_at` is, so unmarking is a write of `NULL`. A one-way toggle on a list being triaged is a trap: one mis-tap and the row you had not read is indistinguishable from the forty you had ("no way back", confusion type 4).

**Unread is legible without reading a pill.** The card is **violet-tinted** while unread and white once read, *and* carries a violet `unread` pill — colour is never the only signal (design rule), and fill and pill are the same hue so they read as one statement. ~~The card is yellow while unread.~~ **History — corrected in review:** a full `--yellow` fill already means *warning* one click away, on `/admin/users`, where the only yellow-filled card is the default-password banner; ten of fifteen rows unread made this screen read as ten alarms. **Mood is not a pill: it is the same face the sender tapped**, mint for a smile and peach for a frown, at the footer's own resting treatment. A smile and a frown are different *shapes*, so the state survives being read in greyscale, which two pastel pills would not. Tangerine was the rejected alternative for "not good" — it is the system's one-forward-action colour, and three tangerine badges down a list read as three alarms on a screen that has no forward action at all.

**Consequences:**
- `Entry.admin_changeset/2` casts exactly `[:read_at, :admin_note]`, the narrow shape `Accounts.User.admin_changeset/2` uses: an admin endpoint must not be able to smuggle an edit of the sender's own words through the same `cast/3` that marks a row read. Pinned by a test.
- The note is free text, so invariant 11 applies to it too: no `maxlength`, `Entry.max_admin_note_length/0` (1000) in the changeset, a live grapheme counter per row. Each row's textarea takes an **explicit** `id` — every row's field is `note[body]`, so the id `<.input>` derives from the field name would repeat and LiveView would patch the wrong textarea. `Phoenix.LiveViewTest` raises on duplicate ids, which is how this was caught.
- **`/admin/feedback` is not in the header's `⋯` menu**, and it should be. That menu is in `ConsensusWeb.Chrome`, which this piece does not own; the two admin screens cross-link to each other directly instead (`#admin-feedback-link` on `/admin/users`, `#admin-users-link` on `/admin/feedback`). Adding an entry beside "Admin" there is outstanding work.
- **An unsaved admin note is never thrown away, and that is a rule about `load_entries/2` — and, since D-045, about navigation too.** As written this bullet was false across a navigation: every control in the global footer and the header `‹` is a `navigate` that remounts the LiveView and rebuilds every note form from `entry.admin_note`, so a typed note was silently replaced by the previously *saved* value. `AdminLive.Feedback` now passes `footer_confirm`/`back_confirm` whenever any row's draft differs from what is stored. The rest of this bullet is unchanged and still true of this screen's own events: The obvious implementation rebuilds every row's note form from the database on every event; that destroys the draft on the *normal* triage path ("read it, write down what I did, mark it read") with no flash, no confirm and no undo. `load_entries/2` therefore takes the list of ids it may reseed — only the row an event actually wrote — and carries every other row's draft forward. The over-long-note branch of `save_note` reloads nothing at all and names the real cause with the real numbers ("That note is 1001 characters and the limit is 1000"); it must never fall into the generic "reload the page and try again" branch, because reloading is the one action that would also destroy the text the flash is asking to trim. Pinned by three tests in [test/consensus_web/live/admin_live/feedback_test.exs](../test/consensus_web/live/admin_live/feedback_test.exs).
- **`Entry.sender_label/1` falls back to `"no name given"`, not `"signed out"`.** The card prints the account line separately, so the old fallback made one of the two slots carry no information. The name slot answers "who"; the metadata line answers "was an account attached".
- **The metadata line says `signed in` or `no account linked` — never `signed out`.** `feedback.user_id` is `ON DELETE SET NULL` *on purpose* (D-042), so a `nil` there means "sent signed out" **or** "sent signed in, and that account was deleted afterwards", and the screen cannot tell which. It printed "signed out" for both, asserting something false on a screen whose whole posture is that it prints only what is true. Distinguishing the two honestly would need a `sent_signed_in` boolean written at submit time; the current phrasing is exactly true in all three cases without one, and adding the column is the change to make if the distinction ever earns its keep.
- **The cross-link on `/admin/users` carries the unread count**, from `Feedback.count_unread/0` — which `load_entries/2` also uses, so the number on the two screens has one implementation. Without it an admin who never taps the link never learns anything is waiting, and this link is still the only route in.
- `Consensus.Feedback` publishes nothing over PubSub. The queue is a triage list an administrator opens on purpose, not a live surface; product invariant 4 ("results are real-time") is about voting. A new entry appears on the next load.

---

## D-044 — The swipe deck is a second *view* of the ballot; the sticker grid stays the default

**Date:** 2026-08-09
**Status:** settled
**Context:** `docs/plans/chrome-and-feedback.md` piece P5; design frames
[`1c-0-swipe-deck-kept-in-play.html`](design/screens/1c-0-swipe-deck-kept-in-play.html) and
[`1c-1-sticker-grid-kept-in-play.html`](design/screens/1c-1-sticker-grid-kept-in-play.html),
transcribed in `docs/design/IMPORT-NOTES.md` §7 and §8.

**Decision.** `/join/:slug/vote` renders one of two views of the *same* ballot, chosen by a
segmented `Grid` / `Swipe` switch that appears on both of them. The grid is the default. Nothing
below `ConsensusWeb.JoinLive.Ballot` changed: the same `@approved` / `@veto_id` socket assigns, the
same single `Consensus.Voting.cast_ballot/3` write, invariant 17 untouched, no new route, no schema
change, no new context function.

**Why the grid stays default.** The design section both frames come from is titled *"Option-picking
— ranked list is the lead, the other two stay in play"*, and `1c-0`'s own caption is `swipe deck ·
kept in play`. The deck is explicitly the retained alternative, not the recommendation. It is also
the view that needs a pointer: the grid shows the whole pool at once, renders and submits with no
hook of its own, and needs no gesture vocabulary. (The one `phx-hook` inside the grid's column is
`#ballot-unsaved-guard`, a `beforeunload` courtesy added later — the grid works if it never loads.
An earlier version of this line quoted "`main [phx-hook]` count is 0", which the guard invalidated.)

**Consequences.**

- **The switch is the mode signal, and it promises something the code has to keep.** It renders
  above both views as one line: the toggle, and beside it *"Your picks stay when you switch."*
  ~~with an `<.eyebrow>View</.eyebrow>` above it~~ — **the eyebrow was deleted by D-046's
  consolidation sweep and this entry was not amended with it**, so it kept describing an element
  that is not in `ConsensusWeb.JoinLive.Ballot.view_switch/1`. Grep before quoting: a two-line
  header over a control whose own two buttons already read `Grid` and `Swipe` was the half carrying
  no information, and the reassurance is the half a voter needs before touching a control that
  looks like it might reset something. `handle_event("set_view", ...)` `push_patch`es to the same
  URL with only `view` changed
  — the selections **and the deck's position** ride along in the query string untouched. The
  position half is not decoration: the grid's URL used to be the bare route with no `card`, so
  `handle_params/3` re-derived `deck_index` from a missing param and `Grid → Swipe` restarted the
  deck at card 1 every time; from the end-of-deck summary that also took `#submit-ballot` off the
  screen and re-showed every card as already decided. Pinned by "switching views loses nothing",
  "switching views keeps the deck's position, not just the picks" and "switching views from the
  end-of-deck summary comes back to the summary" in `ballot_test.exs`.
- **Gesture semantics** (the frame annotates none — IMPORT-NOTES §7.6): swipe right = ♥ approve,
  swipe left = ✕ pass, and **veto is button-only, never a swipe**. A voter gets exactly one veto and
  it eliminates the option for everyone; that does not belong on a flick. The three controls, their
  geometry and their left-to-right order are the frame's: a white `✕` circle, a tangerine
  `1×` square with a `VETO` caption, a violet `♥` circle, all `shadow-sticker-3`. Pass and
  approve **darken their fill on hover instead of pressing** — the one hover in the import that
  does, because they have no room to press (IMPORT-NOTES §9.1); the veto presses, as
  the frame draws it. ~~58 / 44 / 58.~~ **Corrected by D-046 to 62 / 48 / 62**: §7.6's 58 and 44
  are *content* boxes plus the 2px border each side the same section specifies, and everything else
  on this card was converted from content-box to border-box on the way in.
- **Every gesture has a button, and the buttons are peers rather than a fallback.** They are the
  only path for a keyboard, a screen reader or a desktop browser. Verified by renaming the hook to a
  name LiveView cannot resolve: the console logged `unknown hook found for "SwipeCardTEMPMISSING"`
  and both the grid and the deck's three buttons kept working.
- **`--color-violet-deep` (`#5A38DD`) and `--color-yellow-tint` (`#FFF6DC`)** were added to the
  `@theme` block. The second one also **replaced the grid card's `hover:bg-yellow`**, which the
  ballot's moduledoc used to record as a deliberate deviation "because there is no token" — there is
  one now, and it is the frame's actual value. **`--shadow-sticker-5` was deliberately not added**,
  though the plan's token table lists it for this piece: the frame gives the deck's top card
  `box-shadow:4px 4px 0` (`--shadow-sticker-4`), and the only things drawn at 5px are the 300×600
  mockup device bezels, which DESIGN-SPEC says not to build. Adding a token with no caller would be
  dead code.
- **The deck answers "how much more is there?"** with the frame's `N / M` counter (confusion #6),
  and the stack thins as it goes — `Sticker.deck_stack/1` takes `behind` and draws 0, 1 or 2 cards
  underneath. The counter is the real signal; the stack is decoration supporting it. `behind` is the
  count of **undecided** cards after this one, computed by `undecided_after/3`; it was briefly the
  positional `count - index - 1`, which agreed with the documented meaning only on a straight
  forward walk and drew two ghost cards behind a `Change`d card with nothing undecided after it.
- **The whole ballot lives in the URL — navigation *and* selections.** `@view`, `@deck_index` and
  `@deck_changing?` come from `?view=deck&card=N&changing=1`; `@approved`, `@veto_id` and
  `@deck_seen` come from `?picked=1,5&veto=7&seen=1,5,7`. Every control that moves the voter or
  changes a selection `push_patch`es, with `replace: true` for a selection change so ten taps in the
  grid are one history entry rather than ten. **This entry used to say the opposite** — "selections
  live in assigns … nothing in `handle_params/3` writes `@approved` or `@veto_id`, which is what
  makes Back cost nothing" — and that was wrong in a way that cost the voter their ballot. Assigns
  do not survive a **mount**, and a mount is not an edge case:
  - browser Back onto any entry this process did not create (a reload, a second visit, the
    entry-screen redirect) remounts, and on Android Back is an edge swipe — on the one screen in
    this app that teaches horizontal swiping;
  - a **LiveView reconnect** — a screen lock, a tab switch, a cell handoff. Measured at 360×844:
    two picks and a spent veto (`2 PICKED · 0 VETOES LEFT`) became `0 PICKED · 1 VETO LEFT` after a
    400ms `liveSocket.disconnect()`/`connect()`, with no reload, no flash and nothing on screen
    saying so. The voter walks the rest of the deck believing their earlier picks are in, and D-036
    locks the short ballot they send. The `UnsavedBallot` guard disarmed itself in the same blip.

  A URL survives all of it for free, with no client-side copy of what is picked and no
  `sessionStorage` to re-sync — the grid still needs no hook of its own. `handle_params/3` hydrates
  **only when the selection assigns are absent**, i.e. on a real mount; inside a live session the
  process keeps its own state, so stepping Back through the deck reverses the *movement* and not the
  votes (that is `Undo`'s job). Everything read out of the query string is clamped and filtered:
  `?card=99` resolves to the summary, `?picked=4,999999,nope` keeps only ids that are in this pool,
  and a veto is never left also approved. `JoinLive.Entry`'s two bounces are `replace: true` for the
  other half of the original bug — they used to append a history entry per visit, so Back could
  never leave the ballot at all.
- **Undo is an addition, not in the design.** `@deck_history` is a stack of whole-state snapshots,
  one pushed per decision, so `Undo` restores the card index *and* the selections it changed. A
  swipe is easy to do by accident and a mis-aimed veto is expensive. Navigation (`Review picks`,
  `Change`, `Keep going`) pushes no snapshot — undo reverses decisions, not movement, and Back now
  reverses the movement instead. Three corrections came out of the first critic round, all of them
  the same failure (a control whose visible effect was not what it claimed):
  - it is labelled **"Undo last card"** with `aria-label="Undo — put back your answer on <name>"`.
    A bare "Undo" sitting inline beside "Keep going" reads as navigation;
  - pressed **from the summary it stays on the summary**, so the voter watches the row change. It
    used to throw them into the deck and take `#submit-ballot` off the screen with it, one press
    after they had pressed "Review picks" — so the visible effect read as the navigation being
    undone while the vote quietly went too;
  - while a `Change` is open it is **replaced by `Cancel change`**. Undo one tap after Change reads
    as "cancel this change" and was not: it reversed a decision three actions old, dropped the
    change mode and jumped to a different card.
- **The end-of-deck state is designed here** (IMPORT-NOTES §7.7 has none; plan ruling 7 settles the
  shape): "Your picks", one row per option with `Picked` / `Vetoed` / `Passed` / `Not looked at —
  counts as a pass` and a `Change` button, then the same `N PICKED · N VETOES LEFT` line and the
  same tangerine `Send my votes` the grid has. `Change` re-opens one card and returns to the summary
  after it is decided, announcing that while it is doing it. It is reachable early through `Review
  picks`, so it handles cards nobody has looked at, and offers `Keep going` when there are any.
  Reaching the end having picked nothing is **not** a dead end: it says why the button is inert and
  names the two ways forward. The heading is conditional on whether anything was **picked**, not on
  whether the ballot is sendable — a veto alone makes it sendable, so "Your picks" appeared over a
  counter reading `0 PICKED`; the three states are "Your picks", "Nothing picked, one vetoed" and
  "Nothing picked yet". The subhead under it pointed the voter at a list whose only control is
  `Change` ("Pick at least one below") and named picking as the only way to enable Send when a veto
  also does; it now matches `#ballot-empty-hint` three lines below it, which was the accurate one of
  the two. The summary's `<h1>` also takes
  `tabindex="-1"` and `phx-mounted={JS.focus()}`, because the last decision deletes the card view
  and a keyboard user's focus fell to `<body>` at the exact moment the screen changed meaning.
- **`Review picks` is unconditional in the deck.** It is the deck's only route to the submit button,
  and a voter who tapped three cards in the grid and then switched over arrives at card 1 with
  nothing decided *in the deck*.
- **Both views now say submitting is final, above the button** — "Sending is final — you can't
  change your votes afterwards." D-036 locks a cast ballot and there is no recast, and nothing on
  the ballot said so before the press. Not a modal: a confirmation dialog would add a step to the
  common case for a fact a sentence can carry. `submit_block/1` also owns the *inert*-button
  explanation now, in each view's own words (`empty_hint`); it lived in the deck's summary only,
  so the grid — the default view — showed a dead button with no sentence saying why. It owns its own
  16px gutter too: the summary wrapped it in a second one, making the same control 356px wide there
  and 388px in the grid, visibly under-hanging the list above it.
- **The veto behaves identically in both views** — it moves to a second card rather than refusing,
  and pressing it on the card that already holds it **releases** it and stays put. That last half
  was not true when this entry was first written: the deck re-applied the same veto and advanced,
  while its `aria-label` had always read "Remove veto on <name>", so the one control that promised
  to give a voter their veto back was the one control that could not. The glyph reports state
  (`1×` / `0×`) and the `aria-label` carries the full sentence. **The captions are now the same
  three in both views** — `VETO` / `MOVE VETO` / `VETOED`. The grid briefly used only `VETO` /
  `VETOED`, to avoid printing `MOVE VETO` down every remaining card; what that produced instead was
  four buttons reading `VETO` under a counter reading `0 VETOES LEFT`, two things on one screen
  disagreeing about the same fact. The thing that actually read as "nine vetoes" was the `1×` glyph
  printed once per option, and **that is gone from the grid** — the budget is stated once, in
  `N VETOES LEFT`. The deck keeps the glyph, where there is exactly one of it and it is a counter.
  A veto that *moves* says so in a line ("Your veto moved from X to Y — you only get one."), **in
  both views now**: the grid used to move it in total silence, the previous holder simply ceasing to
  be struck through somewhere in a two-column list the voter was not looking at. It is cleared by
  the next decision or any movement. With `group.veto_allowed == false` there is no veto affordance
  in either view **and no copy referring to one** — `submit_block/1`'s `empty_hint` hardcoded "or
  veto the one you can't do", so the one sentence whose job is unsticking a voter with an inert Send
  button sent them hunting for a control that is not on the screen and that
  `Voting.ensure_veto_permitted/2` would refuse.
- **A reload is guarded, because nothing else guards it.** The `UnsavedBallot` hook arms the
  browser's own `beforeunload` prompt from the same condition `leave_confirm/2` uses for the header
  pill, read at event time off `data-unsaved` so the hook holds no copy of what is picked. The deck
  makes this worse than it was for the grid — it turns the ballot into a long sequential walk a
  stray pull-to-refresh erases. `beforeunload` does not fire on LiveView's own pushState, so
  submitting and the pill are unaffected.
- **Tangerine on the ballot is the forward action and nothing else.** The grid's per-card veto is
  `bg-peach` when held, not `bg-tangerine`, and the in-card `Vetoed` pill was removed — it announced
  the same state as the labelled control 6px below it (ambiguous duplication, confusion #5) and was
  a second tangerine. The card carries the state through its struck-through name and a `text-faint`
  meta line. The deck's 44px veto button stays tangerine because IMPORT-NOTES §7.6 draws it that way
  and argues for it explicitly — it is the only tangerine on the card view, where there is no submit
  button. **The end-of-deck summary's `Vetoed` pill is `tone={:peach}`, not `:tangerine`**: that is
  the one screen in the deck where `#submit-ballot` renders, and a tangerine pill above it made two
  (measured: `main *` with `background-color: rgb(255,106,43)` returned the pill and the button).
  It was matched to `tally_bar/1` on the *results* screens, where there is no forward action to
  compete with; peach is what the grid's held-veto button already uses for the identical state one
  view away. `Sticker.pill/1` gained a `:peach` tone for it.
- **A selected grid card gets both of frame `1c-1`'s markers, not one.** The mint fill *and* the
  thumbnail switching to the muted-ink `.stripes-ink` pattern, plus the 21px ink `✓` badge — which
  needed `z-10`: `photo_frame/1`'s root is `relative overflow-hidden`, so at `z-index: auto` the
  thumbnail painted over the badge and only a ~2px crescent escaped.
- **`photo_frame/1` takes a `stripe` attr** (default `stripes-violet`, so every existing caller is
  unchanged), because it had the violet placeholder hardcoded in two places — the class list and the
  `onerror` handler. Two callers now pass something else, for the reason app.css's own comment gives
  for having five variants at all ("a pool of five options with one repeated stripe reads as a
  single grey block, and the eye stops separating the rows"): the deck's card passes
  `stripes-mint`, which is what frame `1c-0` draws for the largest region on the screen and what
  IMPORT-NOTES §7.5 names; the grid's thumbnails cycle peach → yellow → blue → violet on
  `rem(activity.id, 4)`, keyed on the id the way `Sticker.participant_avatar/1` keys its fill so the
  colour survives a re-render, matching `1c-1`'s three different pastel tiles. `stripes-ink` stays
  reserved for the selected state.
- **`SwipeCard` in `assets/js/hooks.js`** uses Pointer Events (one path for finger, mouse and
  stylus), locks the axis on the first 6px so a vertical page scroll is never stolen, registers its
  `window` listeners through one `AbortController` that `destroyed()` aborts, and holds **no copy of
  which options are approved** — it reports one decision and lets the LiveView decide. `.deck-card`'s
  CSS is deliberately **unlayered** in `app.css`: cascade layers beat specificity, so a rule inside
  `@layer components` would lose to the card's own `bg-white` utility and the drag hint would never
  paint. Nothing flings a card, so `prefers-reduced-motion` only has to drop the spring-back. Three
  things about it are load-bearing and were wrong in the first cut:
  - **`pointercancel` aborts the drag; it does not commit it.** It was bound to the same `finish`
    closure as `pointerup`, so an Android edge-back swipe, the notification shade or a second finger
    landing handed the voter an approval they never released — on a ballot that locks on submit and
    cannot be recast (D-036). `pointercancel` is, in practice, touch-only.
  - **`suppressClick` is cleared on `pointerdown`, not only where it is consumed.** It exists so a
    drag that ends in a click is not also read as a tap, and it used to be cleared *only* inside the
    click listener — but a click is not guaranteed to follow the gesture that set it. A
    `pointercancel` is by definition never followed by one, and a `pointerup` released off the card
    (which is what a drag released over the control row directly below produces) does not click the
    card either. The flag survived and ate the voter's **next** genuine tap: measured, tap #1 after
    a cancelled drag did nothing at all and tap #2 advanced the deck — the primary affordance of the
    screen silently failing once, right under the line "Tap or swipe right to pick it". It is no
    longer set in the `pointercancel` branch at all.
  - **The commit threshold and the colour are the same distance.** The hint fired at 24px against a
    ~90px commit, leaving a 66px band (19% of the card) where the card was solid mint and letting go
    silently discarded the vote. The threshold is measured once per gesture; `data-swipe-dir` sets
    the hue immediately and `--swipe-progress` ramps the wash, and only `data-swipe-hint` — set at
    the threshold — puts the full fill on.
  - **The wash is an `::after` overlay, not a background on the card.** The photo region is an
    opaque child covering ~84% of the card at 420×900, so a background on the element itself painted
    only the body strip and the direction signal was invisible under the finger. **`inset: 0` on it
    was wrong, and D-046 fixed it**: the veil covered the card's *own name and description* at the
    moment a release would commit, taking the name from 13.9:1 to about 1.4:1 against its
    background. The card body is now `relative z-[3] bg-white`, so the wash paints over the photo
    only. The overlay is still the mechanism; its extent was the bug.
  - **The wash is not the only signal — a `PICK` / `PASS` stamp rides with it.** The approve hue is
    `--color-mint` over a `bg-canvas` page, which is also a pale green: at the commit distance the
    card read as very nearly the colour of the page behind it, with direction carried entirely by a
    hue one of whose two values is the background. `.deck-card::before` carries static content per
    `data-swipe-dir`, so no JavaScript writes it, and `z-index: 2` puts it over the `::after` wash.
- **The top card carries no `phx-update="ignore"`, deliberately.** The plan's hook checklist asks
  for it "where appropriate". It would freeze the server-rendered state note ("You picked this.")
  that has to change when a card is re-opened, because the card's `id` is stable while the voter is
  on it. The drag survives without it on a **stated precondition: this LiveView never initiates a
  render** — no `handle_info/2`, no `subscribe`, no `Process.send_after`, no `handle_async`. Adding
  any of those (a live countdown, a PubSub tally) invalidates it.
- **A tap on the deck's card means the same thing as a swipe right,** handled in the hook with a
  capture-phase click listener that suppresses the click a drag ends in. The grid one switch away
  makes the option card the tap target, so the largest object on the deck answering a tap with
  silence was the same unreadable affordance in reverse. It gets no `role` and no `tabindex`: it is
  a pointer affordance shadowing a pointer-only gesture, and its accessible peer is `#deck-approve`
  directly below it — making the card focusable would put a second "Pick <name>" in the tab order
  ahead of the one the design draws.
- **Touch feedback and touch targets.** `#deck-pass` and `#deck-approve` carry an `active:` fill as
  well as the frame's `hover:` one — `:hover` does not exist on touch, so on a phone the two primary
  controls of this view gave no feedback at all until the server replied. The `Grid` / `Swipe` pills
  got the same treatment for the same reason, having been missed the first time round. The grid's
  per-card veto is `min-h-11`, matching every other control on the screen; at 36px it was under the
  touch floor for the one destructive control a voter can reach, directly under a tap-to-pick card.
- **Each of the deck's three controls is one button containing its shape *and* its caption.** The
  veto's caption used to be a sibling `<span>` 3.5px under the button — `elementFromPoint` over it
  returned the span and `closest("button")` was `null`, so the only text that ever says `MOVE VETO`,
  the sentence explaining the control's most surprising behaviour, was not pressable. `PASS` and
  `PICK` captions were added under the two circles at the same time: they carried a bare `✕` and a
  bare `♥`, and the instruction line above the card maps *gestures* and never says which button is
  which, so a first-time voter had to infer ✕ = pass from the Tinder convention on a ballot that
  locks. The hover/active fills moved to `group-hover:` / `group-active:` on the inner shape.
- **`Review picks` is hidden while a `Change` is open.** `deck_review/2` and `deck_cancel_change/2`
  both patch to the summary with `changing?: false`, so the two pills sitting side by side were two
  controls that appeared to do different things and did not (confusion #5). `Cancel change` names
  the mode it is leaving and is the honest one of the pair.
- **`@deck_seen` is written by the grid too.** It was written only by `decide/3`, so a voter who
  worked entirely in the grid — the *default* view — and then opened the summary was told every row
  was "Not looked at — counts as a pass", a claim about their own behaviour that was false.
- **The deck view carries `overflow-x-clip`.** Measured at 420×900: a 150px drag to the right grew
  `document.documentElement.scrollWidth` from 420 to 587 and the whole page scrolled sideways. `clip`
  rather than `hidden`, which would make it a scroll container and take the vertical axis with it.
- **The *card* is bounded, not the photo inside it.** `Sticker.deck_stack/1` briefly capped its
  photo region at `max-h-[62%]`, because plain `flex-1` — what the frame's CSS literally says — gave
  the photo 84% of a 496px card at 420×900. The cap stopped the photo growing without giving the
  space to anything else: measured, the card was 485px tall with a 75px body and **112px of blank
  white** below the description, a 1.26 height/width ratio against frame `1c-0`'s 303×264 (1.15,
  103px body, 16px trailing padding). The photo is plain `flex-1` again and the caller's `relative`
  box carries a max height, ~~`max-h-[430px]`~~ **`max-h-[380px]` since D-046** — 430 held the
  *card's* ratio near the frame's but left the photo inside it at 1.08:1, a near-square where the
  frame draws 1.33:1, and 380 is what a 1.33:1 photo plus this card's ~79px body needs at the
  column's full 440px. The text block is
  `shrink-0` with `line-clamp-2` on both lines and the photo floor dropped to 72px, because
  `.deck-card` is `overflow: hidden` and at 360×640 the card bottomed out at its 220px floor with
  `scrollHeight` 224 against `clientHeight` 216 — the padding gone and, with a longer name, a whole
  line of the description vanished with no ellipsis. Invariant 11's rule for this same `description`
  field: the failure mode has to be an ellipsis, not a vanished line.
- **`Sticker.deck_stack/1`'s root is `absolute inset-0`,** not `relative`. Every layer inside is
  absolutely positioned, so the element has no content height: as a plain `relative` div it measured
  0px and the three cards rendered as ink hairlines, and `h-full` measured 4px because a percentage
  height does not resolve against a `flex-1` parent whose own height is `auto` until layout.
- The card's photo region is `photo_frame/1`, so a missing or dead `image_url` degrades to a
  placeholder stripe (invariant 14) — `stripes-mint`, which is what the frame draws and what
  IMPORT-NOTES §7.5 names. It was violet for one round on the argument that a second "missing photo"
  pattern would stop the pattern meaning "missing photo"; that argument does not survive app.css
  already shipping five variants for exactly this, and it put a violet hue at double the frame's
  stripe pitch on 298px of a 485px card. The frame's meta row (`Italian · $$$ · 4.5 ★ · 0.8 mi`)
  collapses — none of it exists in
  `Consensus.Activities.Activity` and none of it can until Places/Yelp lands (Post-MVP).

---

## D-045 — A dead end is a defect: off-site next steps get a screen, every branch gets an exit, and a draft gets a prompt

**Date:** 2026-08-09
**Status:** settled

**Context.** Walking every flow turned up one failure repeated in eight places: a screen that leaves the reader with nothing to do. `docs/plans/chrome-and-feedback.md` names seven kinds of confusion; four of them are represented here, and none of them is a wording problem.

### 1. A flash is the wrong instrument when the next action is off-site

`put_flash` is a transient strip drawn over a screen that still looks exactly like the one the reader just acted on. That is correct for on-site, recoverable, low-stakes feedback — "Link copied", "Zahav saved" — and it is exactly wrong when the next real step is *go and open your email*, because "the page did not change" is the reader's evidence that nothing happened. Three flows ended that way and now render a **full-page state of the LiveView that produced them**:

| Flow | Was | Is |
|---|---|---|
| magic-link log-in | flash + `push_navigate` **back to the log-in form** | `UserLive.Login`'s `@send_state` branches (~~`@sent_to`~~ — split into `{:sent, _}` / `{:refused, _}` by D-049 §2) |
| magic-link registration | flash + `push_navigate` to the log-in form | `UserLive.Registration`'s `@sent_to` branch |
| change-of-email confirmation | flash, staying on a settings form still showing the **old** address | `UserLive.Settings`'s `@email_sent_to` branch |

**The rule for deciding**, so this does not become "convert every flash": a flash becomes a screen when the reader's next action is **off-site**, or when the screen would otherwise offer nothing. Everything else stays a flash.

All three share `CoreComponents.check_your_email/1`, which answers four questions in a fixed order — what happened, **which address** it went to (mono, `break-all`: the commonest failure here is a typo the sender cannot see in a form they have already left), what to do next, and **what to do if it does not arrive**. That fourth is not padding; without it the screen is a prettier dead end, because the reader has nothing to do but wait. Each therefore offers a real resend and a real way back to correct the address.

**No new routes.** A success state is a state of the screen that produced it. `/check-your-email` would be bookmarkable, and would then assert a send that never happened to whoever opened it — naming an address nobody typed. `FeedbackLive`'s existing thank-you (D-042) is the same shape and the precedent.

**The enumeration property of the log-in screen is preserved, and must stay preserved.** The magic-link copy hedges ("If that address is in our system…") because confirming whether an address has an account is a leak. The sent screen renders from the address typed into *this browser* alone — ~~`@sent_to`~~, which **D-049 §2 replaced with a three-valued `@send_state`** because a screen with two states could not tell "sent" from "refused by the cap" and claimed the former for the latter; quote `@send_state` — and `deliver_magic_link/2` stores that address unconditionally on the same code path whether or not `Accounts.get_user_by_email/1` found anything. `Send it again` re-enters the identical branch, with no "we already sent one" state and no rate-limit message, both of which would be behaviour that differs by address. Which of the three states is reached is likewise a function of presses in this browser and never of the address. Pinned by a test that renders the screen for a known and an unknown address and asserts the two are **byte-identical** once the address itself is substituted out — an assertion no amount of careful wording can satisfy accidentally. Do not add a "we couldn't find that address" branch, a different heading for a known address, or a delivery receipt.

**The `/dev/mailbox` pointer is gated on `Application.compile_env(:consensus, :dev_routes)` *and* the mailer being `Swoosh.Adapters.Local`** (`CoreComponents.dev_mailbox?/0`). The route is mounted by the first, so gating on the adapter alone can render a link to a route that does not exist; the second is the other half of the question, since the route existing is not the same as mail landing there. It is worth having: an email that never arrives is the single most common way a developer loses an hour on these three screens.

### 2. Every branch of every screen renders an exit

Two screens had combinations that rendered **nothing**.

- `JoinLive.Results` was three `:if`s, and a `:completed` group in a browser that had never voted matched none of them: a latecomer saw an outcome and had no exit whatsoever. It is now a `footer_state/2` table over `{:voting, :completed, :cancelled} × {:voted, :joined, :stranger}`. Several cells collapse onto the same footer; they are still written one per line, because the failure was a *missing combination* and a table cannot hide one. ~~Nine clauses.~~ **D-046 made it `footer_state/3` with ten**, splitting `{:completed, :stranger}` on whether this mount saw the group `:voting`; the arity and the count are history, the table discipline is not. A test per cell, each asserting `#results-start-your-own` — whatever state a visitor arrives in, there is a labelled way off the screen.
- `GroupLive.Results` had branches for `:voting` and `:cancelled` only, so a finished session rendered nothing below the tally — and with an outcome of `:no_consensus` or `:no_votes` there was no winner card above it either, leaving the organizer with **no control anywhere on the page**. `:completed` now names the outcome and offers `Start another session`; `:cancelled` says it cannot be reopened and offers the same.

The post-vote screen was the worst instance in the app — the last thing every voter sees, at the end of the flow the product exists for, offering a banner and one sentence about a feature that does not exist. It now says the three things a voter actually wants: the tally is live and moves by itself, the wall-clock time it closes (`Deadlines.label_for/3`, which needed a `tz_offset` this LiveView did not read), and a door out.

Two silent redirects were given a voice: `/groups/:id/share` and `/groups/:id/results` on a `:draft` group both bounced to `03 review` with no flash and no explanation. Asking for the share link and getting a different screen, on a wizard, reads as a failure.

### 3. `return_to` on re-authentication, validated

`AdminLive.Users`' sudo flash promised "You will come back to Admin → Users" and could not keep it: `user_return_to` was written only by `maybe_store_return_to/1`, a plug on GET requests, and that navigation originates in a LiveView with no conn. The promise had already been removed once (D-041); it is now **built** instead. `require_sudo/2` navigates to `/users/log-in?return_to=/admin/users`, `UserLive.Login` renders it as a hidden `user[return_to]` on the password form, and `UserSessionController` calls `UserAuth.store_return_to/2` before `log_in_user/3`.

**Validation is the whole risk.** This writes a value a *successful authentication* then redirects to, which is the most valuable place in an app to have an open redirect, because the victim arrives already convinced. `store_return_to/2` accepts only what `ConsensusWeb.CurrentPath.safe_return_to/1` accepts — a single-slash absolute path — so a scheme, a host, and both protocol-relative spellings (`//host`, `/\host`) are refused, silently, falling through to `signed_in_path/1`. A rejection must never become an error message that teaches the filter's shape. ~~Pinned by a test that walks six hostile spellings.~~ **History — corrected in §9:** those six were the ones the filter already caught. `safe_return_to/1` was a *prefix* check and passed three shapes `Phoenix.Controller.redirect/2` itself refuses, so the failure mode was not an open redirect but a **500 after a correct password**. It is a character check now, and the test walks nine.

**The stale admin could not reach the trip at all.** `require_sudo/2` is the `handle_event` path, and in exactly the state it exists for, every Promote/Demote/Delete on the page renders `disabled` — so it is unreachable from a fresh mount, and `#sudo-notice`'s "Log in again" link is the admin's only affordance. That link shipped as a bare `~p"/users/log-in"`: following it stored no `:user_return_to` (the pipeline answers 200 and never halts, so `maybe_store_return_to/1` never runs) and `signed_in_path/1` delivered a re-authenticated admin to Account settings. It carries the same `?return_to=/admin/users` now, with its own test, because no test that pushes the event by hand can see a disabled button's real path.

**Only the password form completes the trip, and the copy says so.** A magic link is delivered to a mailbox, which is routinely opened on a different device from the one holding the tab, so "come back to where you were" is not a promise that route can honour; appending a redirect parameter to an emailed authentication link is also new attack surface for no gain. The promise is rendered **inside `#login_form_password`**, above its submit, and it names the form: "Logging in with your password brings you straight back to where you were." The magic-link form carries its own line saying what it will and will not do.

*This took two attempts and the first one reinstated the defect it was fixing.* The promise first went into the shared header paragraph — which renders directly above the **magic-link** form, 220px above the password form and the hidden `user[return_to]` behind it. Measured at 420×900: the promise at y=157, `#login_form_magic` at y=324, `#login_form_password` at y=546. A reader who took "Logging in below brings you straight back" at its word tapped the one tangerine primary action on the page and landed on `signed_in_path/1`. "On the form that keeps it" has to mean *inside that form's element*, not "somewhere on the same screen"; it is now pinned by a test that splits the rendered HTML at `id="login_form_password"` and asserts the sentence falls on the far side.

### 4. Irreversibility is announced before the press, not after

- **The pool freezes when voting opens** (D-037). `GroupLive.Review`'s warning existed but named the wrong trigger: "Once you share this, the options are locked in" says the lock happens when the link is sent. It does not — `handle_event("publish", …)` flips the group to `:voting` the instant the button 12px below is pressed, before any link has left the screen. An organizer reading it literally taps "Get the share link", assumes the pool is editable until they paste it into the group chat, and finds `‹` goes back to a review page with no ▲▼ and no ✕. Now: "Tapping this opens voting — the options lock now: no adding, removing or reordering."
- **The deadline closes voting and picks a winner with no organizer action** (product invariant 3). Said at the point of choice (`GroupLive.New`, already), at the point of commitment (the same review sentence), and on both results screens where a deadline is displayed.
- The ballot lock is `JoinLive.Ballot`'s and was already stated there.

Copy rather than a second `data-confirm`: two dialogs on one screen trains people to dismiss both, and this is a forward action, not a destructive one. The genuinely destructive control on that screen — the per-row remove `✕` — did get one, matching `/groups/:id/options` word for word.

### 5. The draft-loss escape hatch is wired

D-041 shipped `Layouts.app/1`'s `footer_confirm` and `Chrome.footer/1`'s `confirm` and left them with **zero call sites app-wide**: measured, `data-confirm` count was 0 on `/users/register`, `/groups/new` and `/feedback`, and 0 of 6 footer links on `/admin/feedback`. Every control in the global footer is a `navigate`, so a tap remounted the LiveView and the typing was gone with no confirm and no undo — and `?return_to=` then returned the visitor to an *emptied* form, which is what made the round trip read as safe.

`Chrome.header/1` and `Layouts.app/1` gained the missing third member of the set, **`back_confirm`**. The `‹` is a `navigate` too and it is the control *nearer* the form; a screen that guards the footer and not the `‹` has plugged the far door and left the near one open.

Both are now passed by all six screens that hold a draft — `user_live/registration.ex`, `user_live/settings.ex`, `group_live/new.ex`, `group_live/options.ex` (the `:edit_activity` branch only), `feedback_live.ex`, `admin_live/feedback.ex` — **gated so the prompt only appears once there is something to lose**, the shape `JoinLive.Ballot` uses for `pill_confirm`.

The gate is "differs from what is stored", not "non-empty", wherever a form arrives pre-filled: settings' username and email, the `01 setup` form in `:edit`, the option editor, and `FeedbackLive`'s Name field (seeded from a signed-in sender's username). Otherwise the prompt fires on a form nobody has touched, and a warning that is usually wrong is one people learn to dismiss — which is the confusion this guard exists to prevent. For the same reason `AdminLive.Feedback` compares each row's draft against `entry.admin_note` rather than taking the cheaper "prompt whenever `@open_notes` is non-empty": `open_notes/2` seeds itself open for every row that already carries a note, so on a triaged inbox that would prompt on every navigation with nothing at stake. Verified live at 420×900: six note panels open with saved notes, prompt disarmed; one character typed into `#note-body-22`, prompt armed.

`FeedbackLive`'s moduledoc asserted "there is no footer tap that can remount this LiveView and lose a draft". That was true of the mood pair only, which `Chrome.show_mood_pair?/2` drops; it is corrected in place rather than deleted, because the mood-pair half is still true and still load-bearing.

### 6. Touch targets on controls that had none

Measured at 360×640 with `getBoundingClientRect` plus an `elementFromPoint` hit-scan, re-measured after:

- `/groups/:id/review`'s **▲/▼** painted 7.8×10 with 8×11.5 and 8×13 hit boxes and a 2.0px gap — unhittable with a finger, and adjacent enough that a miss did the opposite of what was intended. They are now **44×44 each, stacked in a single 44px-wide column with a 4px gap**, and the row grows to ~92px to hold them. *(The first cut put them side by side and was wrong: growing them horizontally took 72px out of a 360px row, leaving the option name at 120px — narrower than "Superiority Burger" at the row's own 700/14px, 123px — so ordinary fixture names ellipsised on the last screen before an irreversible publish, under a subhead reading "This is what everyone votes on". Re-measured stacked: the name is 168px at 360, and "Reading Terminal Market" at 166px clears it. The 4px gap is what matters between them, not the axis: a near-miss at a shared boundary is the failure mode, and 4px of dead space turns it into a miss.)*
- The per-row **remove ✕** was 16×24 with `data-confirm` null — the smaller, harder-to-hit copy of the same destructive action `/groups/:id/options` renders at 28×36 *with* a confirmation, on the screen immediately before publishing. Now 44×53 effective via the `before:-inset-[14px]` pattern `Chrome.header/1` uses, with the same confirmation string.
- **"Drag to reorder" was unfollowable on a phone.** `Sortable` binds `dragstart`/`dragover`/`dragend` and nothing else; no mobile browser fires HTML5 drag-and-drop from a finger, and the hook's own comment claimed it "uses … pointer events on touch", which was simply false. Both are fixed by telling the truth rather than by writing a pointer-event path: the comment is corrected, the subhead leads with "Tap ▲▼ to reorder — or drag, on a computer", and the ⠿ handle is `[@media(hover:none)]:hidden` so it only paints where dragging works. Teaching `Sortable` pointer events remains a reasonable future change; it was not made here because the ▲▼ pair is now a full-size control and the instruction no longer lies either way.
- `/admin/users`' **Delete** was 37.3×18, starting 8.0px right of a 77.6×34 Promote with its whole vertical band inside Promote's, styled only `text-[12px] text-muted hover:text-tangerine` — and `hover:` does not exist on touch, so on a phone nothing distinguished it from body text and nothing acknowledged a tap. Now the same 34px pill geometry, 16px clear of Promote, with tangerine as the `active:`/`hover:` **press** state rather than the fill (a screen gets one tangerine forward action, and this is neither).
- Two **sole-exit links** under the 24px floor were padded to 44px with cancelling negative margins so the text does not move: `/groups/:id/share`'s "See live results →" (324×18.8, and the only forward control on a screen with no tangerine at all) and `/groups/:id/results`' "Get the share link again →" (320×18.8).

### 7. Two false promises deleted

- **Nudging does not exist.** `grep -rn 'nudge' lib/` finds no path, the organizer's own control is `disabled` and labelled `Soon`, and `/about` says in as many words that this app sends no notifications. The organizer's half of the shared component had been corrected; the participant's had not — `avatar_caption="ORGANIZER NUDGES"` rendered unconditionally, and "Only {organizer} can nudge or close early" rendered on `:completed` groups, telling a voter the organizer could "close early" a vote that had already closed. Caption → `WHO'S VOTED` on both halves; the sentence is gone.
- **Nothing in this app ranks anything.** `JoinLive.Ballot`'s moduledoc says "there is no ranking anywhere in here" and `Consensus.Voting.Vote`'s says "there is deliberately no rank or weight column here". The mint banner a voter saw immediately after casting said "Your ranking is in" — the highest-stakes instance of the verb, on the one screen that confirms a guest's only action. → **"Your votes are in."**, echoing the button one screen earlier ("Send my votes").

Separately, `GroupLive.Results`' `nudge_label/1` keyed only on `waiting_count(participants) == 0`, which an **empty** participant list satisfies exactly as a fully-voted one does — so the first thing an organizer saw after publishing, before anyone had opened the link, was `0/0 voted` above "Everyone has voted". **A state with nothing to press does not get a control at all**: with no participants the marker is not rendered, and a plain `#results-nobody-yet` sentence takes its place beside "Close now". *(The first cut kept the disabled box and only rewrote its two lines, to "Nobody has opened the link yet / SHARE THE LINK" — an imperative printed on something that cannot be pressed, 100px below the working `Get the share link again →`, explained only by a hover `title` that does not exist on touch. That is the same confusion class in a new spelling, which is why the box went instead of its label.)* ~~Where the marker does render, the sub-label stays an availability marker in one register — `Soon`, `All in` — never an instruction.~~ **History — finished in §9:** `Soon` and `All in` are not one register, they are two axes ("the feature is unbuilt" and "everybody voted") in one 8px mono slot, and the fully-voted state was the same status-sentence-in-a-control this bullet had just removed from the empty state. The marker renders only while `waiting_count > 0` now, so `Soon` is the only sub-label there is, and `#results-all-voted` is the sentence for the other end.

### 8. What the first critic round found, and what it cost

Everything above shipped and was then walked by four adversarial reviewers. Six of their findings were defects this entry had *introduced* — a dead end removed by adding a different one — and they are recorded here rather than quietly patched, because the pattern in them is the lesson.

**A placeholder password made a security warning fire on every no-password signup.** `UserLive.Registration`'s magic-link mode satisfied `registration_changeset/3`'s `validate_required([:password])` by injecting a random string. That left `hashed_password` non-nil, and `hashed_password` is the *only* field `UserSessionController.clears_password?/1` reads — so opening the emailed link greeted every brand-new account with "You are logged in. The password that was set on this account has been removed — choose a new one under Settings", naming a password the person had never chosen, thirty seconds after a screen that told them there was nothing to log in with. That controller's own comment says the warning must not cry wolf; it was crying wolf on 100% of the path. `User.registration_changeset/3` now takes **`require_password: false`** — it lifts the `validate_required` and nothing else, the `cast/3` list is untouched (CLAUDE.md invariant 6), and `Accounts.register_user/2` passes it through. A magic-link account is now genuinely password-less, which is the shape D-017 leaves behind anyway. Walked in a browser: register → open `/dev/mailbox` → confirm → the flash reads ~~"User confirmed successfully."~~ **"You're in — this address is confirmed." since D-048** — that quoted string was the generator's, a schema noun in the third person on the first screen a new account ever sees, and the whole point of this entry is which sentence greets that person.

**A cancelled session was painting a winner's star.** `Voting.tally/1` gates only `winner?` on `status == :completed`; `leader?` survives a cancellation, and `Sticker.tally_bar/1` paints its tangerine ★ from `leader?`. So both results screens rendered "Alpha Diner ★ 1" under a **Final tally** heading on a screen that said twice — in the panel and in the footer — that the session was cancelled and nobody won. `ResultsComponents.presentable_tally/2` strips `leader?`/`winner?` for a cancelled group before either LiveView computes `outcome/1`. The approvals, vetoes and bars are untouched: what people voted is still true, only the crown comes off.

**"The deadline passed" was said to organizers who had closed the session by hand.** `:completed` is reached two ways — `Activities.maybe_complete_group/1`'s lazy sweep, and the **Close now** button in the same file — and `finished_note/1` inferred *how* from the fact that it had happened. `finished_note/2` now takes the `%Group{}`: the sweep stamps `completed_at` at or after `deadline_at`, so an earlier `completed_at` means a person pressed the button. The vacuous "everyone who voted can still open the link" tail is also dropped from the `:no_votes` branch, where there is no "everyone".

**"Voting closed before you got here" was told to people who were here.** (Twice, in the same corner of the table — the `:stranger` half of it survived this fix and was corrected in D-046.) `footer_state(:completed, :joined)` mapped onto `:closed_missed`, and `:joined` means this browser holds a participant token — which can only be minted while the group is `:voting`. Their own avatar sits on the same screen captioned "you". It has its own cell now, `:closed_no_ballot`: "Voting closed before your votes went in." Enumerating nine cells stops one rendering *nothing*; it does not stop one being wrong, and the wrongness here was the same inference the paragraph above makes — reading *how* someone arrived off *that* the session ended.

**The `⋯` menu was the last unguarded door.** §5 wired `back_confirm` and `footer_confirm` on all six draft screens and measured seven `data-confirm` elements on `/groups/new`; the three links inside `Chrome.header/1`'s `⋯` panel carried none, so tapping Settings from a half-typed form took the draft with it silently. They take `back_confirm` too — it is the header's prompt and they are the header's other exits. Re-walked: with a title typed, `window.confirm` fires and Cancel keeps you on `/groups/new`.

**Two more, smaller:** `back_to_settings` left `email_draft?` at the `false` `update_email` had set, so the one state where there is provably something unsaved — the form returning with the typed address still in it — was the one state with no prompt on its exits; it recomputes from `differs?/2` now. And `resend_email_change` opened with `true = Accounts.sudo_mode?(user)`, a correct guarantee expressed as a crash, on the control in the app most likely to be pressed after a long idle (its screen exists to be left open while you go to your inbox). It branches instead, into the re-auth trip §3 built.

Alongside them, three touch targets this entry had walked past on screens it was already editing — `/groups/:id/review`'s **Cancel this group** (now "Cancel this session" — D-047; 97.8×18, styled with nothing but `hover:`, guarding an irreversible action that discards other people's ballots), `/users/log-in`'s **Log in only this time** (312×19.5, 12px under a 60px button whose accidental press leaves a persistent session on a shared device), and `/join/:slug`'s **Continue as …** (141.4×40.5, on the first screen a guest ever touches) — plus `/groups/:id/share`'s **QR** button, which was `disabled` while wearing the full enabled sticker treatment and explained only by a `title` tooltip. All four are 44px and, where they are inert, dashed and flat like every other unbuilt control in the app. Cancel's confirm now names the loss the way `/admin/users`' Delete does: "1 person has already voted; their ballot is discarded and no winner is picked."

Writing the test for that last one surfaced a defect none of the four critics reached: `GroupLive.Review` subscribes to `"activity_group:<id>"`, `Consensus.Voting` publishes `{:participant_joined, _}` and `{:ballot_cast, _}` on that same topic, and the LiveView had no clause for either — so an organizer sitting on the review screen of a live group crashed to the reconnect banner the moment anybody joined. Both are handled.

**The reusable lesson.** Five of the six regressions above are the same move: *keeping the shape of a broken control and rewriting its words*. A disabled box whose label became an instruction, a promise moved to a paragraph instead of into the form, a caption swapped on a control that still could not be pressed. When a control is wrong because it cannot do what it appears to offer, the fix is to stop rendering the control.

### 9. What the second critic round found

Four more reviewers walked it again. The findings fall into three groups, and the third is the one worth remembering.

**Three security-shaped defects, none of them the one §3 was worried about.**

- **`safe_return_to/1` failed open into a 500 on the authentication endpoint.** It was a prefix check — a leading `//` and a leading `/\` — and `Phoenix.Controller.redirect/2` refuses three further shapes by *raising*: a `\` anywhere, `/%09`, and a literal tab (`@invalid_local_url_chars`). So `?return_to=/%09//evil.example` was accepted here, rendered verbatim into the hidden field, and turned a correct password into `500 Internal Server Error` with the browser still signed out. Phoenix's own guard is what stopped it being an actual open redirect; this app contributed nothing. It is now a character check — `\`, `/%09`, and `[\x00-\x20\x7F-\x9F]` (which covers the literal tab, every other C0 control, space and DEL) — the same rule `Consensus.Feedback.Entry.safe_page_path/1` applies to the stored `page_path` it renders as an `href`. The two are kept as separate functions on purpose: they guard different sinks, and neither should quietly inherit the other's loosening. The hostile-spelling loop walks nine now, and the three new ones assert a *redirect to `/`*, which is what proves no raise happened.
- **Signing in destroyed a guest's ballot.** `renew_session/2` clears the whole session to defeat fixation and took `"participant_token:<group_id>"` with it — a guest has no account (product invariant 1), so that key is the *only* record that they joined a vote and cast it. Measured: vote, tap the header's "Create your own →" (rendered on every `/join` screen), log in, and `/join/:slug/vote` bounced back to name entry, where `JoinController.resolve_guest/3` — whose only dedupe *is* that key — would mint a second participant row. Guests carry `user_id: nil`, so the partial unique index does not catch it, and the tally counted one person twice. Those keys are now preserved across both log-in and log-out, the way the generator's own comment on that function invites. They are ballot receipts, not credentials: they authorize nothing, the ballot they unlock is already locked (D-036), and they name no account. Fixation is a reason to drop the identity in the session, not the guest's record of what they did before acquiring one.
- **An unopened email-change link stayed armed for seven days.** `deliver_user_update_email_instructions/3` only inserted; the `delete_all` lived on `update_user_email/2`'s *success* path. So a typo'd address held a working token that moves the account's email onto a stranger's mailbox, and "Send it again" added a second live token beside the first — while the recovery screen this entry built for exactly that moment said the sent link "simply expires unused". A false safety claim on an account-recovery path is the worst place in the app to be reassuring and wrong, so **the code changed rather than the sentence**: every outstanding `change:<current_email>` token is deleted before the new one is inserted. The test that asserted two tokens after a resend now asserts one.

**One more unbounded control and one more 404.** `handle_event("resend", …)` on the registration sent screen was new capability — before this entry, that path had no resend at all and re-registering is blocked by uniqueness — and registration does not verify the address, so anyone could register with a third party's address and hold the button down. Bounded at two, in the handler rather than only on the button. And `GroupLive.Results`/`Share` let `Activities.get_group!/2`'s `Ecto.NoResultsError` reach the browser as a bare 404, which two ordinary paths walk into: an organizer pasting `/groups/:id/results` into the group chat instead of the share link, and `:user_return_to` surviving a log-in as a *different* identity (measured landing a brand-new account on Not Found as the very first screen after "Account created"). Rescued into a named redirect to `/`. The authorization is unchanged — nothing of the other user's group is rendered — only the response to being refused.

**And the group worth remembering: the fix was applied to one instance of a defect that existed in several.** `UserLive.Login`'s 20px "Log in only this time" was corrected and the two byte-identical copies in `UserLive.Confirmation` — the mandatory landing screen for every passwordless user — were left untouched, with the report quoting the *unfixed* screen's measurements as evidence of the fix. Three sent-screens were built in one change and two got a 44px correction control while registration's wrapped into two 15px line boxes. `/groups/:id/results` dropped the nudge marker for the empty-participant case and kept it for the everybody-voted case, where "Everyone has voted / ALL IN" is the same status-sentence-in-a-control shape §8 says to stop rendering. `home_live.ex` and `how_it_works_live.ex` lost the word "rank" and the option editor's helper kept it. In every case the miss was mechanical, not judged: a `grep` would have found it. **When a fix is applied, grep for its pattern across the tree and fix every hit before reporting.**

The remaining corrections are copy, and all of them are the same failure as §8's: a sentence that outlived the code it described. "Nothing was confirmed to it and nobody can sign in with it", twenty lines under the address a working sign-in link had just been mailed to. "Change Email" on a button that changes nothing, whose success state has to bold a negation to walk the verb back — now "Send a confirmation link". "You can change your password any time", shown to magic-link registrants who by §8's own fix no longer have one — now "set". "Nobody has to press anything", on a screen whose organizer has a live **Close now** button. Two whitespace-significant link bodies reading "the mailbox page ." and "Change it now ." (invariant 11 / D-026) in files this entry was already editing.

**Consequences:**
- `CurrentPath.safe_return_to/1` is a **character** check, not a prefix check, and it must stay at least as strict as `Phoenix.Controller`'s `@invalid_local_url_chars`. Anything it accepts is handed to `redirect/2`, which raises rather than refuses — so a loosening here does not open a redirect, it 500s the log-in endpoint.
- `UserAuth.renew_session/2` preserves session keys prefixed `"participant_token:"`. Anything else added to that session is still cleared, and should be: the exception is for guest ballot receipts specifically, not a general "keep useful things" rule.
- `Accounts.deliver_user_update_email_instructions/3` supersedes outstanding tokens for the same context. `UserLive.Settings`' recovery copy states that as a fact; the two are a pair.
- `UserAuth.on_mount({:require_sudo_mode, path}, params, …)` builds the return path from `params` as well as the caller's base, because a LiveView can serve more than one route — `UserLive.Settings` serves two, and the emailed confirm-email link is the one that routinely exceeds the window. A second screen adopting the tuple that also has a parameterised route needs its own clause in `sudo_return_to/2`.
- `Sticker.participant_avatar_row/1` takes `waiting_label`; `ResultsComponents.results_panel/1` passes `"missed it"` once the group is not `:voting`. Additive, defaults to `nil`.
- `GroupLive.Results`' nudge marker renders only while `waiting_count(@participants) > 0`. Both zero states are sentences (`#results-nobody-yet`, `#results-all-voted`) — do not reintroduce a control for either.

**Consequences (from §1–§8):**
- `CoreComponents.check_your_email/1` and `dev_mailbox?/0` are the only additions to that module; both are append-only.
- `Chrome.header/1` and `Layouts.app/1` take `back_confirm`. It is additive and defaults to `nil`; passing `footer_confirm` without it is the mistake to look for in review.
- `UserAuth.store_return_to/2` is public and is the only writer of `:user_return_to` outside `maybe_store_return_to/1`. Any new caller must pass a caller-supplied path *through it*, never `put_session(conn, :user_return_to, …)` directly — the validation is the point.
- `UserAuth.on_mount/4` takes **`{:require_sudo_mode, return_to}`** as well as the bare `:require_sudo_mode`, and `UserLive.Settings` uses the tuple. A hook has no conn, so the destination travels in the log-in URL; the path is written in the screen's own module, not read off the request, and `store_return_to/2` re-validates it on the way back regardless. `on_mount(:require_authenticated, …)` and `on_mount(:require_admin, …)` were deliberately **not** given the same treatment: the plug `require_authenticated_user/2` already stores `:user_return_to` for the HTTP GET that precedes any socket connect, so a signed-out deep link into `/groups/:id/share` already comes back to it (verified end to end with a cookie jar: `GET /groups/1/share` → 302 → `POST /users/log-in` → 302 to `/groups/1/share`). Those hook clauses are reachable only when a token dies between the static render and the socket connect, and `on_mount` is handed no URI to build a `return_to` from.
- `ResultsComponents.presentable_tally/2` sits between `Voting.tally/1` and `Voting.outcome/1` in both results LiveViews. A third caller of `results_panel/1` must apply it too, or a cancelled session crowns a front-runner again.
- `Chrome.header/1`'s `back_confirm` guards the `⋯` menu's entries as well as the `‹`. Any new entry added to that panel takes `data-confirm={@back_confirm}` — a menu that guards two of three exits is decoration.
- `JoinLive.Results.footer_state/2` is total over the statuses and participations that exist. Adding a fourth group status now fails to match, loudly, in a test, instead of silently rendering an empty footer. Keep it total. **Arity superseded by D-046: it is `footer_state/3`, and the third argument (`saw_voting?`) is written out explicitly on every clause — including the eight that ignore it — so the table stays exhaustive rather than acquiring a catch-all.**
- The enumeration test in `login_test.exs` compares two full renders. It will fail on any change that makes the sent screen depend on anything but the typed address — which is exactly what it is for.

---

## D-046 — The consolidation sweep: one scroll model per screen, 16px on every field, and a cap that covers every sender

**Date:** 2026-08-09
**Status:** settled

**Context.** Five critic panels ran against one working tree while four pieces were being built in it. Most findings were routed to the piece that owned the file; these are the ones that were not, either because their owner had finished or because they crossed several pieces. They are recorded together because several of them are the *same* mistake in different files, and the value of the entry is the pattern, not the list.

### 1. A screen picks one scroll model, and `Layouts.app/1` now says which

`Layouts.app/1` grew **`fill_viewport`** (default `false`). Off, the column is `min-h-dvh` and the page is the scroller — right for almost everything, and what a phone browser handles best. On, the column is `h-dvh` and a screen may put a `min-h-0 overflow-y-auto` region inside `<main>`.

This is not a preference. **Without a height-bounded ancestor, `flex-1 min-h-0 overflow-y-auto` on a descendant does nothing at all** — an auto-height flex container grows to its content, so there is never any overflow to scroll. The ballot's grid shipped with exactly that markup and no bound, so the page scrolled instead: measured at 360×640 on a five-option pool, `documentElement.scrollHeight` 934 against `innerHeight` 640, `#submit-ballot` bottom at **851.86 — 212px below the fold**, `#ballot-status` below it too. The first screenful ended mid-pool with neither the counter nor the one action the screen exists for, and nothing indicating either existed. Frame `1c-1` specifies the opposite in its own markup (`flex:1;min-height:0;overflow-y:auto` on the pool, `Send my votes` pinned under it), and IMPORT-NOTES §8 names `overflow-y:auto` on the grid as new in the import. It was a specified state that was not built, and the deck work is what pushed it past the fold: the VIEW toggle is 66px and the new full-width VETO pills add 50px a row.

After: `scrollHeight === 640`, the grid track scrolls internally (560 > 198) and `#submit-ballot` ends at 557.75. **Amended by D-047 §1: `h-dvh` became `.viewport-column`, which clamps only above 640px of viewport height, and the track's `min-h-0` became a `min-h-[200px]` floor.** The measurement above stands; what was wrong was that the clamp applied at *every* height, and with `shrink-0` siblings a short viewport then drove the track to 16px and painted the submit button on top of the footer.

~~**`fill_viewport` is the ballot's grid view and nothing else.** The deck stays on the page scroller — one card and a control row, no list to scroll, and an end-of-deck summary that grows.~~ **Superseded by D-047 §2:** the deck's *card* state keeps the page scroller for exactly those reasons, but its **summary** is a second adopter. A list that grows past the viewport is what a scroll track is for, and leaving it out reproduced this very blocker on the deck's only route to Send — `#submit-ballot` at 695–755 in a 640px viewport. `GroupLive.Options`' pool list carries the same inert `min-h-0 overflow-y-auto` and was deliberately left alone: it is a *finding for another day*, not a silent conversion, because its screen is a form and turning it into a fixed-height column changes how the whole wizard scrolls.

### 2. Every text field is at least 16px, and the frames are wrong about this

iOS Safari zooms the page whenever a focused field computes under 16px, and does not zoom back. Four fields were under it: `add-option-query-0` (14px — the field the entire creation flow types into), `activity_name` (15px), and the shared `CoreComponents.input/1` **textarea** clause at 13.5px, which is every textarea in the app — the option description on `02b` and `entry_message` on `/feedback`. The insult on `/feedback` is specific: `entry_name` and `entry_email` were already 16px, so on a phone the name and email behaved and then the one multi-line field the screen exists to collect threw the layout.

All four are 16px. The frames specify 13–15px (IMPORT-NOTES §6.3 pins `400 13.5px/1.45` on the textarea) and **a static mockup measured in a design tool is not evidence about focus zoom on a phone**. The join-entry field had already been raised to 16px for exactly this reason, so the precedent existed and was simply not swept. The rule from here: no `<input>` or `<textarea>` in this app goes below 16px, whatever a frame says.

### 3. A cap on one of two identical mail primitives is not a cap

`login.ex` and `settings.ex` capped their **resend button** at two presses. Both left the *initial* send — `submit_magic` and `update_email` — unbounded, and over an open socket pushing one event costs no more than pushing the other, so the cap was bypassable by name. Both screens now hold **one budget for the whole screen** (`@max_sends 4`), spent in a single private function (`deliver_magic_link/2`, `deliver_email_change/3`) so no future control can add a send that escapes it. Four is one send plus three corrections, which is more than the "use a different address" loop needs.

**The cap and the enumeration property do not conflict, and this is the reason to write it down.** `sends_left` lives in socket assigns and counts presses in *this browser*, so it is a pure function of the typed string exactly like every other byte of `login.ex` — a registered and an unregistered address exhaust it at the same count with byte-identical output, `#magic-link-resend-exhausted` included. Pinned by a test that exhausts both and compares the two renders with the address substituted out. The screen still has no "we already sent one" state and no rate-limit *message*, because either would be behaviour that differs by address.

The lede branches on the budget rather than on the address, for honesty: at zero it would otherwise have said a link was on its way when nothing had been sent.

Unbounded, this was an inbox-flooding primitive — an unauthenticated endpoint, an attacker-supplied recipient, and a real sign-in link carrying this app's From: domain per press. Measured before the cap: `users_tokens` where `context = 'login'` went 25 → 32 on one submit plus six presses, with 13 live links to one address. `settings.ex` is milder (sudo-gated) but its recipient is a **new** address, so a mistyped or hostile value lands in a mailbox the account owner does not control. `registration.ex` was already bounded and is unchanged; its initial send is additionally bounded by email uniqueness. **A per-mount counter is not a rate limit** — a reload resets it — and it is not sold as one; a real limit belongs at the endpoint and is recorded in `open-questions.md`.

### 4. Consent has to be on screen whenever the action is

`/feedback`'s action bar is `sticky bottom-0` (IMPORT-NOTES §6.5), opaque, and 94px. The scroll body reserved no space for it, so wherever the bar was stuck it deleted that much live content with nothing scrollable underneath: measured at `scrollY === 0` against the 110px `#entry_message`, **16.4px of 110 visible at 360×640** (placeholder entirely hidden), 40.4 at 390×664, 76.4 at the frame's own 420×700. Focus did not rescue it — Chrome will not scroll a partially-visible element and knows nothing about an overlay — so the caret line stayed occluded *while typing*, and the bar's 2px ink top border read as the end of the page.

The body now reserves the bar's height. **And the default-on capture-consent row moved into the bar**, which frame `00c` §6.4 does not draw. A `sticky` Send is reachable without scrolling by construction, so reserving space makes the consent row *reachable* but not *seen*: at 420×700 its top was at 663.6 in a 700px viewport with everything below 606 behind the bar, `elementFromPoint` at the label's centre returned the bar, and Send sat at 620–680 fully hit-testable. A sender could submit without ever seeing what was ticked. **A default-on checkbox the sender cannot see is the same lie as one the app ignores (D-042), told from the other side**, and consent belongs adjacent to the action it qualifies. The row keeps §6.4's geometry, its 44px label and the literal path beneath it.

### 5. A star is a claim about the count, not about the organizer's drag order

`Voting.tally/1` gives `leader?` to exactly one survivor and breaks ties by `activity.position`. That is correct and deterministic for the *domain* — `outcome/1` needs a single answer — and wrong as a *statement to a voter*: on "Alpha 1 ★ / Beta 1 / Gamma 0" the star went to whichever option the organizer happened to place higher on `03 review`, an ordering no voter has seen and cannot reason about.

Fixed in presentation only, in `ResultsComponents`: while the group is `:voting`, every survivor sharing the highest count carries the star and the legend reads **`★ TIED FOR THE LEAD`** instead of `★ LEADING RIGHT NOW`. ~~The star is tangerine.~~ **D-047 §6 made the running-tally star and its legend violet**, because starring N rows turned one tangerine glyph into N and the shared rule is that tangerine appears once per screen as the one forward action; the `:completed` winner card's badge is still tangerine. `Voting.tally/1` and `outcome/1` are untouched, and the override is `:voting`-only — once a group is `:completed` the same glyph means `winner?`, announced once in the green card, and starring several rows there would contradict it. **Picking a winner out of a genuine tie at completion is still open** and is not answered here; what is answered is that the tie must not be hidden while the vote is running.

### 6. Copy that infers *how* someone arrived from *that* it ended

D-045 split `{:completed, :joined}` out of `:closed_missed` for saying "Voting closed before you got here" to a browser holding a participant token. The `:stranger` cell — a guest who opens the link and reads the tally without joining, which is the **more** common arrival — kept saying it. Screenshot pair 20 seconds apart on one never-reloaded page: at 11:03:24Z the footer offered "Cast your vote" over "Closes Today 7:03 AM — voting locks then, on its own", the deadline passed at 11:03:32Z, the LiveView flipped in place, and the same page then asserted the reader had arrived too late.

`footer_state/2` became `footer_state/3`, taking `saw_voting?` — captured at mount, never cleared — and `{:completed, :stranger}` now has two cells: `:closed_just_now` ("Voting just closed.") and `:closed_missed` for a genuinely cold arrival. The third argument is written out on every clause, including the eight that ignore it, so the table stays exhaustive rather than acquiring a catch-all.

### 7. The rest, briefly

- **The swipe wash covered the card's own words.** `.deck-card::after` is `inset: 0`, so at the moment of commit an 0.85 mint veil sat over the name and description as well as the photo — the name's contrast against its own background fell from 13.9:1 to roughly 1.4:1, erasing the one piece of information saying what was being voted on. The frame draws no wash at all, so this is invented chrome: the card body is now `relative z-[3] bg-white` and the wash is scoped to the photo.
- **Stripe pitch is a variable now** (`--stripe-pitch`, with `.stripe-pitch-6`). The frames scale it with the element — 5px on `03 review`, 6px on `1c-1`'s 38px thumbnail, 10px on `1c-0`'s deck photo — and one 9px band everywhere made Kismet's violet stripe visibly twice the width of Guisados' blue on adjacent cards. `thumb_stripe/1` also dropped violet: it cycled four pairs where the frame draws three, and the invented member was the coarsest.
- **The deck's three controls were 4px small** — 58/44/58 border-box against the frame's 62/48/62. IMPORT-NOTES §7.6's 58/44 are *content* boxes plus a 2px border each side; everything else on the card was converted and these were missed.
- **The deck card's photo cap is derived, not eyeballed.** `max-h-[430px]` gave a 1.08:1 near-square photo at 420×900 — 39% of the viewport as empty striped placeholder. At the column's full 440px the card is 400px wide inside its borders and a 1.33:1 photo wants 301px, so with this card's ~79px body the cap is **380px**. The photo's *share* of card height (78%) still differs from `1c-0`'s 64.7% and cannot be fixed from this end: the frame's 264px card carries a 108px body, ours carries the same two lines on a card half again as wide. The aspect is the one that shows.
- **Two yellows on adjacent controls.** The grid's VETO pill hovered to `--yellow` (#FFD84D, the header pill's resting CTA fill) while the option card 6px above hovered to `--yellow-tint` (#FFF6DC, the frame's only declared grid hover). The louder, CTA-coloured one was on the destructive control; both are `yellow-tint` now.
- **The ballot's three centred lines are one status region.** The counter, the empty hint and the D-036 irreversibility warning were three sibling paragraphs in three barely-different treatments. They are one bordered block with a weight ramp. The warning stays **unconditional** — the moment to learn that sending is permanent is while you are still deciding.
- **Grid cards fill their row.** Grid rows stretch to the taller cell; the shorter card kept its intrinsic height and its VETO pill rode up with it, 60px out of line with its neighbour.
- **`/how-it-works` gained its missing first step.** The frame's four begin at "Add the options", so nothing said the organizer names the session and sets the deadline — then step 4 opened "When the timer runs out…", a definite article for an object nothing had introduced, and the CTA dropped the reader onto `/groups/new`, whose only two inputs are exactly those two things. Five steps now; step 5 says "the deadline you set".
- **`/admin/users`' row actions are 44px**, matching `/admin/feedback`. Two sibling admin screens had different button metrics, and one of the three buttons deletes an account.
- **`/privacy` gained two `<.sticker_card>`s and lost an arrow.** 1341px of seven identical eyebrow-over-paragraph blocks in which the only shadowed element was the CTA; the two a reader comes for (the anonymity limit, how to get data deleted) are cards. Its CTA read `Start something →` where `/how-it-works` reads `Start something`; the two standing pages now agree. Home keeps its `+`, which frame `00` draws and which is a create glyph, not a directional affix.
- **`/users/register`'s in-page "Log in" link** was the one exit D-045's draft sweep missed — with text typed, seven controls carried `data-confirm` and this one, directly above the form, did not.
- **`#results-nobody-yet` moved above the button it motivates.** State, then action.

**Consequences:**
- `Layouts.app/1` takes `fill_viewport`. Additive, defaults to `false`, and it must stay `false` by default. A second screen turning it on needs a frame that is itself a fixed-height device with one internal scroll track, and every sibling of that track needs `shrink-0` — **and, added by D-047 §1, the track itself needs a `min-h-[…]` floor, because `shrink-0` siblings are precisely what collapses it on a short viewport.**
- `CoreComponents.input/1`'s textarea clause is **16px**. Treat a `text-[1[0-5]…]` on any `<input>` or `<textarea>` as a regression, the way invariant 11 treats a `maxlength`.
- `UserLive.Login.max_sends/0` and `UserLive.Settings.max_sends/0` are public for the tests. `UserLive.Registration` still uses `@max_resends`, because its initial send creates an account and is bounded by email uniqueness.
- `ResultsComponents` computes the star from the rows it is given (`mark_leaders/2`, `:voting` only) and `Voting.tally/1` is unchanged. A third caller of `results_panel/1` gets the tie handling for free; anything reading `leader?` **from `tally/1`** still gets exactly one.
- `JoinLive.Results.footer_state/3` — see the annotation on D-045.
- `.stripes-*` read `var(--stripe-pitch, …)`. A new call site at a new size sets the variable rather than adding a colour.
- `/feedback`'s consent row is in the action bar, deviating from frame `00c` §6.4's ordering. Recorded here and in `docs/design/DESIGN-SPEC.md`'s `00c` block.
- Deliberately **not** fixed, and recorded in `open-questions.md` instead: `/feedback`'s `Send feedback` renders at the app-wide primary-button metric (60px / 16px radius / `shadow-sticker-4`) against the frame's 48 / 15 / `shadow-sticker-3`. `<.button variant="primary">` is shared by every screen in the app, and matching one frame by overriding the primitive on one screen buys frame fidelity at the cost of the thing a design system is for. **D-047 §6 widened the record rather than the fix: the same deviation holds for `00b`'s CTA and the ballot's `Send my votes`, and `DESIGN-SPEC.md` now states it once for all three instead of naming one and leaving two silent.**

---

## D-047 — The second consolidation pass: bound heights get a floor, outcomes get a name, and one label per action

**Date:** 2026-08-09
**Status:** settled

**Context.** D-046 landed the first consolidation sweep and a critic panel then ran against it. Roughly half of what came back was the *same* fix applied at the wrong end — a cap on the wrong box, a copy branch on the wrong condition, a sweep that stopped one control short — which is why this is one entry rather than a list of unrelated patches.

### 1. `fill_viewport` clamps only where the clamp fits, and the scroll track has a floor

D-046 §1 is right about what `fill_viewport` is for and wrong about it being free. `h-dvh` clamps at **every** viewport height, and every sibling of the ballot's grid track is `shrink-0`, so once header (48) + view toggle (66) + heading and hint (62) + status region (~100) + submit (60) + footer (58) exceeds the viewport, `flex-1 min-h-0` drives the track toward zero and the overflow is painted over the footer rather than being reachable. Measured on a five-option pool: at 375×500 the track floored at **58px**; at 667×375 — an iPhone SE rotated, one gesture away, and the ballot has no orientation lock — at **16px**, with `#submit-ballot` ending 59px past `<main>`'s bottom edge and printing over "Made with ❤️ in Philadelphia". There was no page scroll to escape into, because `h-dvh` is exactly what replaced the `min-h-dvh` that used to provide one. Proved causal by toggling the two classes on the live page: `h-dvh` → track 16px, submit 59px past `main`; `min-h-dvh` → track 515px, no overflow.

Two changes, and they are one fix in two places. `Layouts.app/1` now emits **`.viewport-column`** (`assets/css/app.css`, unlayered so it beats the utilities): `min-height: 100dvh` always, and `height: 100dvh; min-height: 0` only inside `@media (min-height: 640px)`. Below the threshold the page is the scroller again, which is the behaviour every other screen has and the behaviour this one had before `fill_viewport` existed. The grid track carries **`min-h-[200px]`** instead of `min-h-0` — any explicit `min-height` clears a flex item's `min-height: auto` and so does `min-h-0`'s job. The gate is **640px**, the shortest common phone portrait and the viewport the whole fix was measured at: at 360×640 the track is 204px and `#submit-ballot` ends at 557.75 against a footer at 581.75, and at 320×640 (the narrowest phone, so the tallest chrome) the track sits on its floor with 9.9px of slack. 600 was tried and is 12px too low — measured at 360×600 the submit button ended 11.9px past `<main>`.

D-046's own consequence bullet warned that a second adopter needs `shrink-0` siblings. It did not notice that `shrink-0` siblings are precisely what breaks a short viewport. Both halves are now in the attr doc.

### 2. The deck's summary is the second adopter, and it had the same defect the grid was fixed for

D-046 §1 left the deck on the page scroller on the grounds that its summary "grows". A list that grows past the viewport is what a scroll *track* is for, and leaving it out reproduced the original blocker on the deck's only route to Send: at 360×640 on the same five-option pool `#submit-ballot` sat at 695–755, entirely off-screen, with `#ballot-status` below the fold. `fill_viewport` is now `fill_viewport?(view, group, deck_index)` — true for the grid, and for the deck **only in its end-of-deck state**, keyed on `is_nil(current_card/2)`, the same condition the markup branches on. The picks list is the track (`flex-1 min-h-[110px] overflow-y-auto`); the deck's *card* state keeps the page scroller, because it has no list. **110px, and the difference from the grid's 200px floor is the whole point of the number:** this entry first recorded `min-h-[160px]`, which is the value that was tried and *rejected* — at 360×640 there are 146px left for the list, so a 160px floor pushed `#submit-ballot` 14px onto the footer, the same class of overflow the grid's unconditional clamp caused. A floor has to be smaller than the smallest slot it will ever sit in; copy the reasoning, not the constant.

### 3. `outcome/1` gained `:vetoes_only`, because `:no_votes` was lying on a live screen

`Voting.outcome/1` fell through to `:no_votes` whenever no option had approvals and not every option was vetoed — reachable with real ballots, because a voter may spend their veto and approve nothing and `cast_ballot/3` takes that ballot. Observed on `/join/dxKByHE/results`: `1/1 voted`, a green voted avatar, a struck-through option wearing a tangerine `VETOED` pill, and between them a card reading "Voting closed before anyone cast a ballot." The database disagreed with the sentence in two independent ways at once.

The new outcome is computed from the tally alone (`Enum.any?(tally, & &1.vetoed?)` — a veto row can only exist if a ballot carried it), so the function stays pure and no caller changes shape. It covers two sub-cases with one sentence true of both: nobody approved anything, and the only approvals landed on options that were then vetoed. `:no_votes` now means exactly "nobody voted", which is what every screen rendering it says, and `ensure_not_empty/2`'s `{:error, :empty_ballot}` is what makes that airtight.

### 4. One action, one label; and a screen may not assert a send it refused

- **`/users/settings` asserted a link it had not sent.** D-046 §5 moved the send budget onto `deliver_email_change/3` so `update_email` shares it, and branched `login.ex`'s lede on the budget for exactly the reason the branch exists — "the first sentence would otherwise be false on a send the cap refused". `settings.ex`'s lede was left unconditional. Walking the path this screen *instructs*: exhaust the budget, press "Back to settings — the address was wrong", retype a corrected address, submit → zero tokens minted, and the screen reads "It changes when you open the link we just sent to: <address>" with no "Send it again" button anywhere on it. The lede is branched on a new `@email_send_refused?` — the fact, not `@sends_left`, because the reader may have arrived on the last successful send — and the exhausted line now names the real remedy (reload), because "go back and try a different address" is the path that had just silently failed.
- **`/join/:slug/results`' `:closed_just_now` blamed the deadline for a hand-closed session.** `saw_voting?` records that the group was `:voting` at mount and nothing about how it ended. `GroupLive.Results` already carried a `closed_early?/1` written for this exact mistake — "it used to tell an organizer who had just closed a session with 1d 12h left that the deadline passed" — and it was not grepped for. The same predicate is now on both screens.
- **`Send magic link`, everywhere.** `/users/log-in`'s primary read "Log in with email →" for a press that logs nobody in: it mints a token, mails it, and swaps the screen for "Check your email". `registration.ex` already labelled the identical action "Send magic link".
- **`Start something`, everywhere.** `/` said "Get started" for the same `~p"/users/register"` that `/how-it-works` and `/privacy` call "Start something", and the same label the signed-in home already uses.
- **"Session", not "group", on screen.** Six strings still used the schema's noun for the thing every other string calls a session — including `Cancel this group` on the organizer's one irreversible action, landing on a screen that says "This session was cancelled." "Group chat" stays; it means a chat group.
- **`/groups/:id/review`'s veto rule is not dining vocabulary** ("A vetoed option drops out for everyone") and is **not drawn dashed**, which in this repo is the documented "not built yet" treatment. See `DESIGN-SPEC.md`'s `03` block.
- **`/join/:slug`'s `~10 sec` pill is derived.** It sat third in a row of two computed pills and was the same literal for a 3-option pool and a 30-option one — the class of unbacked claim D-046 §4 deleted from `/how-it-works`. Frame `1a-8` prints `5 SPOTS` beside `~10 SEC`; two seconds an option is the rate, and at five options the app renders what the frame draws.
- **`/` has a `:page_title`.** It was the only user-facing LiveView without one, so `<.live_title default="Consensus" suffix=" · Consensus">` collided with itself and the front door named itself "Consensus · Consensus" in every tab, history entry and bookmark.
- **The splash's three cards name the deadline.** Card 1 was "Add anything" against `/how-it-works` step 1's "Name it and pick a deadline" — two first steps for one product, neither mentioning the thing card 3 then leans on.

### 5. Touch targets: the sweep's last three screens, and one comment that was arithmetic-wrong

- **The footer's two mood faces had about a pixel of clearance between them.** Their `::before` grew 4px sideways into an 8px gutter, so the two boxes *touched* — and they file **opposite** moods, which is the one place in this chrome where an overlap is worse than a small target. The faces now have their own `gap-6` wrapper and `-inset-x-2`: a **39 × 37** box with **11px** of dead space between them. (This entry and D-041's amendment both shipped saying `38 × 37` with an 8px gutter — that was the arithmetic, not the measurement. Swept with `elementFromPoint` along the row's centre line at 360×640, HAPPY resolves over 39 discrete columns, SAD over 39, and 11 columns in between resolve to neither.) D-041's numbers are amended in place. The vertical half is unchanged and still short of 44, for the reason D-041 records and re-measured: 11px more takes `Privacy` to 23px, under WCAG 2.5.8 AA's floor, because a positioned pseudo-element beats a static sibling whatever the DOM order.
- **`/groups/:id/options`' `Edit` and `Remove` got the expander the other two screens already had.** 54×28 and 28×36, 4px apart, repeated once per option on the screen the whole creation flow types into — while `Chrome`'s header circles and `GroupLive.Review`'s `×` both reach 44×44 the same way. Both are 44 now, with the row gutter at 16px so the destructive one's box cannot meet its neighbour's, and both insets stay inside the card's own padding so no two rows' Remove boxes can touch.
- **`Sticker.chip/1` carries `min-h-11`.** Every chip in the app painted 39.5px, including the four deadline chips that are the first input on the organizer's first screen. The ballot's view toggle had already been fixed this way and the shared primitive was not swept with it.
- **The footer's standing links are 8px wider each,** via `px-1` paired with `gap-x-1` — 4 + 4 is the frame's 8px of visual space to the pixel, which is what the `gap-x-3` + `px-1` version D-046 threw out got wrong. The vertical `min-h-[26px]` is untouched; D-041 explains why it cannot grow.
- **`.press-*:hover` is behind `@media (hover: hover) and (pointer: fine)`,** and the grid option card's `hover:bg-yellow-tint` gained an `active:` twin. A touch browser synthesises hover on tap and holds it until the finger lands elsewhere, so every pressed control in the app stayed 1px down with a shrunken shadow after the gesture — and on the ballot the yellow tint then competed with the mint `picked` fill the same tap had set. The `:active` rules are deliberately **not** guarded: that is the state touch actually has.

### 6. Smaller, each recorded where it lives

- **The swipe deck's photo carries the ratio, not the card.** Two successive card-height caps (430px, then 380px) were attempts to control an aspect ratio from the wrong end, so it tracked the viewport: 1.08:1, then 1.262:1, against frame `1c-0`'s 1.326. `Sticker.deck_stack/1` puts `aspect-[4/3]` on the photo, drops `flex-1` from it (keeping the default `shrink` so a short phone can still squeeze it) and centres the resulting shorter card in the caller's slot. The photo's *share* of card height lands near 78% against the frame's 64.7% and that is arithmetic, not a bug: at a 380px-wide photo the ratio fixes it at ~286px and this card's body is two clamped lines ≈ 79px, where the frame's 264px card carries a 105px body because it draws three lines. Matching the share as well means inventing card content.
- **The deck's three control captions sit on one line.** `pt-[7px]` centred the 48px veto square against its 62px neighbours by pushing the whole column down, which took its caption with it. A 62px band with the square centred inside does both.
- **The tally star is violet.** D-046 §3's tie fix correctly stars every row sharing the top count — and so turned one tangerine glyph into N, four tangerine elements on one screen against the forward action's one. Violet is the bar's own fill directly below it. The `:completed` winner card's `★` badge stays tangerine: different screen state, exactly one of it, and it *is* that screen's headline.
- **Grid option names are `line-clamp-2`.** A three-line name stretched its row, and its row-mate's `mt-auto` meta line went with it — a 36px void inside one card against 6px in its sibling.
- **`#ballot-status` is `font-medium text-ink-soft`,** which is what frame `1c-1` computes for that line.
- **The grid's veto explainer is dropped once the veto is spent.** At 360×640 the block above the pool measured 192px against a 198px pool — the introduction taller than the thing it introduces.
- **`/admin/feedback`'s one in-page link carries the draft prompt.** D-045's sweep put it on the header `‹` and all six footer controls and missed `Go to Admin → Users`, which discards every open note on the page. Its test **enumerates every anchor** rather than naming controls, because naming controls is what missed it.
- **Passing or approving the card that holds the veto says the veto came back.** `decide/3` releases the veto on any decision, and only the *move* case produced copy; the release's only trace was a counter that on a five-option pool at 360×640 sits below the fold.

**Consequences:**
- `.viewport-column` is unlayered CSS on purpose — a layered rule loses to every Tailwind utility, and this one has to beat `min-h-dvh`. Anything that turns on `fill_viewport` inherits the 640px gate for free and must still give its own scroll track a `min-h-[…]` floor and its siblings `shrink-0`.
- `Voting.outcome/1` has **five** returns. `ResultsComponents.outcome_section/1` and `GroupLive.Results`' `finished_headline/2` (~~`/1`~~ — it takes the tally since D-049 §5, so a tie cannot be announced as a clean win) / `finished_note/2` each grew a clause; a sixth caller must handle `:vetoes_only` or it will fall into a headline that says nobody voted.
- `JoinLive.Entry`'s effort pill is `effort_pill_text/1` over `@seconds_per_option 2`. Changing the rate changes what every share link's front door claims.
- `Sticker.deck_stack/1` no longer wants a `max-h` from its caller. A caller that adds one back re-opens the aspect-ratio bug it was extracted from.
- The `<.button variant="primary">` metric deviation is now recorded in `DESIGN-SPEC.md` for **all three** instances (`00c`, `00b`, the ballot) as one system-wide decision. It was listed for `00c` alone, which read as one recorded exception beside two silent ones. Changing it means changing the primitive, which is a new entry here.

---

## D-048 — The consolidation sweep: a cap that never bound, a winner that was a tie, and a rule that had been amended everywhere except where it was written

**Date:** 2026-08-09
**Status:** settled

**Context.** D-046 and D-047 each landed a consolidation pass and a critic panel ran against the second. What came back split cleanly in two: three defects that were real and reachable on a phone, and a set of documentation facts that had drifted from the code the same entries changed. Both halves are here because the second kind is what produced the first — D-041's border-box rule was amended by two later entries and never edited, so the next builder read a prohibition that the shipped UI had already broken three times.

### 1. The swipe deck painted over its own controls on every short phone

`Sticker.deck_stack/1` bounded the card with `max-h-full` on `.deck-card` inside a `relative max-h-full w-full` sizer. A percentage `max-height` against a **content-height** parent resolves to `none`, so the cap never bound and the card sized itself purely from the photo's `aspect-[4/3]`. Measured at 390×664 (iPhone 14 in Safari): slot 231.5px, card 341.4px, **109.9px of card painted straight over the PASS / VETO / PICK row**, `document.elementFromPoint` returning the card's description at all three button centres — 0 of 78.5 hittable pixel rows each — and `documentElement.scrollHeight === innerHeight`, so there was nothing to scroll to. Same at 375×667 (iPhone SE/8) and 360×640; 40 of 78.5 at 360×700, the height every design frame was drawn at. Fine at 390×844, 420×900 and 1280×800 — and 420×900 was the only viewport it had been checked at.

The consequence is worse than a small target. `SwipeCard` pushes only `approve` and `pass`, so tap and swipe still reached PICK and PASS; **veto had no gesture at all**, which made this app's one-veto promise unreachable by touch on the most common iPhone size.

The fix is two classes at the sizer, not a card-height cap — D-047 §6 removed those deliberately and putting one back re-opens the aspect-ratio bug. The sizer is `relative flex max-h-full w-full flex-col`, which gives `max-h-full` something definite to resolve against and makes the card an ordinary flex item, and the card carries `min-h-0` so a column flex item's default `min-height: auto` (its content minimum) cannot block the shrink. After: **79/79/79 hittable rows at 360×640, 375×667, 390×664, 360×700 and 420×900**, card 231.5 at 390×664 with zero overflow, 420×900 unchanged at card 363.9 and photo 1.333, and 667×375 landscape now scrolls to the row instead of trapping it. Pinned by `"deck_stack/1 — the sizer that bounds the card"` in `sticker_voting_test.exs`, whose comment carries these numbers because an ExUnit test cannot measure any of them.

### 2. `/users/settings` said "No link was sent" and then described the message three times

D-047 §2 branched the lede on `@email_send_refused?` and left the two blocks under it unbranched. `CoreComponents.check_your_email/1`'s `<:fallback>` and the exhausted `<:actions>` line both keyed off `@sends_left`, which is a **different** condition: the budget can be spent on a send that really went out. With the budget spent and nothing sent, the screen read "No link was sent. Your address has **not** changed…" and then, 40px lower, "Check the spam folder at the new address", "the link went to a mailbox you don't own", "a fresh link cancels **the one already out**", and "**That's the last one we'll send** from this page" — plus, in dev, the component's own "The message is waiting in the local mailbox". Five claims about a message that was never created, on an account-recovery path, in the app's most confident voice. A leftover green **Sent again.** flash from an earlier resend sat above the lot.

Both slots branch on `@email_send_refused?` now, the heading becomes "Nothing was sent", and the refused branch of `update_email` clears the flash. `check_your_email/1` gained a `sent?` attr for the one line the component owns rather than the caller. Pinned by `"with the budget spent, nothing on the screen describes a message"`, which asserts the **absence** of each string rather than the presence of the replacement — the failure was extra sentences, so the test has to be able to see one come back.

### 3. The finished session declared a winner out of a dead tie

`results_components.ex`'s `mark_leaders/2` matched `%{status: :voting}` and fell through for `:completed`. So a five-option session with one ballot picking two options rendered both rows starred under `★ TIED FOR THE LEAD` for the whole vote — and the instant the organizer pressed **Close now**, the same never-reloaded screen read "We have a winner — Noodle Bar", demoted Pizza Corner to **Runner-up** at the identical count of 1, dropped the legend, and offered "Copy summary for the group chat". Nothing had changed but the status. The star reverted to `Voting.tally/1`'s tie-break — first by `activity.position`, the order the organizer happened to drag the pool into on `03 review`, which no voter has ever seen.

D-046 §3's reasoning for the `:voting` gate was that starring several rows on a finished group "would contradict the card". That is exactly backwards: it is the card that needs the contradiction shown.

Whether a tie should get a runoff is a genuine open product question and this does **not** answer it — `Voting.tally/1` is untouched and one option still wins. What the screen stops doing is *asserting* an unqualified win over a dead heat. Every tied survivor keeps its star, the legend reads `TIED AT THE TOP`, the card's heading is "Tied at the top" over a `#winner-tie-note` naming the count and the rule that settled it, the row beneath is captioned "Also tied" rather than "Runner-up" when it shares the count, and the clipboard summary — the one artefact that leaves the app, and the only thing most of the group will read — carries the qualification with it.

### 4. The border-box rule had been amended twice and edited nowhere

D-041 said, unstruck and with `Status: settled`, that this app is "uniformly 4px tighter than the frames render… **Do not 'correct' one control to the size its frame paints.** If the whole system is ever re-cut to the frames' painted sizes, that is a new entry, not a fix." D-046 and D-047 then re-cut three controls and called each one a fix, and `chrome.ex`'s moduledoc repeated the dead rule verbatim to the next builder. The shipped UI followed both rules at once.

The prohibition was written to stop a *cosmetic* correction and that part still holds. What it did not anticipate is a control where the 4px costs something a reader can feel. D-041 now carries a table of the four that moved and the standing rule that replaces the prohibition: **the border-box reading is the default, and it is binding wherever a frame states a container dimension that the control's painted size feeds** — `IMPORT-NOTES.md` §3.1's 48px header is `29 + 8 + 9 + 2`, so a 33px `‹` makes frame `4a` contradict itself at 52px, and §4.2's 97px footer is a set with its 26px faces. Elsewhere, re-cut and say so. `chrome.ex` states the same rule and names its own exemption rather than generalising it.

The fourth re-cut is `/feedback`'s own mood pair, 36 → **40px**, with its label 44 → 48 so the frame's 9px circle-to-circle gutter survives (a 40px circle in a 44px label collapses it to 5px). 48 still clears the touch minimum.

### 5. Copy and duplication

- **`"User confirmed successfully."`** was the generator's, and it is the **first** sentence a brand-new account ever sees. A schema noun addressing the reader in the third person, on the screen that finishes signing up — the same class the sweep purged elsewhere. It survived because nothing referenced it: `grep -rn "confirmed successfully" test/` returned nothing. It reads "You're in — this address is confirmed." and the `?_action=confirmed` POST has a test now.
- **`Start something`, actually everywhere.** D-047 §4 recorded the label swap as "everywhere" and the `⋯` menu's signed-out register entry did not move, so the front door and the menu one tap above it named the same screen two ways. `README.md`, `TODO.md`, `DESIGN-SPEC.md`'s `00a` block and two comments in the file whose label changed all still quoted `Get started`.
- **`Log in`, not `Sign in`.** The `:marketing` header was the only one of four controls pointing at `~p"/users/log-in"` — itself, the `⋯` entry, `/users/register`'s in-page link and the destination's own `h1` — calling it something else.
- **`/join/:slug/results` had two `Create your own →`s.** Same label, same `/`, on a screen whose only two controls those were. Matching the wording was D-047's right half; keeping both was the wrong half. `Layouts.app` takes `pill={false}`; the body's copy is the one that survives, because the pill is 10.5px of chrome in the top corner and this is where a guest who has finished is looking. The route-table test asserts the pill's absence **and** `#results-start-your-own`'s presence, so the invariant it was really guarding — a guest always has a labelled way to the product — is still what fails.
- **`:unknown_activity` said "Something in the pool changed".** The pool *cannot* change once voting opens (invariant 16 / D-037), so the flash sent a voter looking for something the app forbids.
- **`/how-it-works`' "Only the organizer can close voting early, and nobody has to be the one who decides"** contradicts itself in plain reading. The reassurance belongs to the deadline and step 1 already carries it verbatim.
- **A card the veto came *off* claimed the voter passed it.** `toggle_veto` ran `mark_seen/2` unconditionally, and `decision_for/4` maps "seen, neither approved nor vetoed" to `:passed` — so vetoing Taco Palace and moving the veto to Sushi Room left Taco Palace reading "You passed on this." in the first person and its summary row labelled `PASSED`, on the last screen before an irreversible send. The card the veto leaves is unmarked now, in both the move and the release case; it genuinely is undecided again.

### 6. Two client-side controls that came back after a re-render

- **`#native-share` was hidden by the hook and un-hidden by every patch.** `NativeShare.mounted()` set `el.hidden = true` where `navigator.share` was missing; LiveView's DOM patch then restored the server's markup, which had no `hidden`, and `mounted()` never runs again. Pressing this screen's own **Copy link** is enough — both outcomes push an event and flash. Measured on desktop Chrome: a 384×105 card of four app tiles with a hover state, `elementFromPoint` at its centre returning `native-share`, whose listener calls an undefined `navigator.share` and throws. The server renders `hidden` and the hook removes it now, with an `updated()` so neither direction depends on a patch not happening. Progressive enhancement has to start from the server's markup.
- **`#pool-list` painted a permanent horizontal scrollbar that scrolls two pixels.** Tailwind's `overflow-y-auto` sets one axis and the other computes to `auto`; the cards' 2px hard offset shadow gives `scrollWidth` 382 against `clientWidth` 380. At 375px wide that reads as a divider, on the screen the organizer spends the most time on. `overflow-x-clip`.

### 7. Two more touch targets, and one finding that was a mis-measurement

`/admin/users`' **"Change it now"** — the single remediation control inside the live bootstrap-password security banner — measured 88×16, under WCAG 2.5.8 AA's 24px floor and the only sub-44 link the sweep missed. `-my-2 inline-block py-2`, the same shape the two auth-screen links use.

**A finding was rejected with evidence, and it is recorded so it is not re-filed.** A critic reported the flash card's top 8px painted over by the header on `/admin/users` at 360×640, citing `#flash-group` at `top: 40` against a header bottom of 48. That measures the **container**; `CoreComponents.flash/1` carries `mt-2`, so the card parks at exactly 48. Re-measured: card `top: 48`, header bottom 48, `elementFromPoint` at the card's own top + 4 returns `#flash-info`, and a screenshot shows the full 2px ink border and both top corners. D-041 states this arithmetic; the 8px lives behind the header where nothing can be seen through it, deliberately.

**Consequences:**
- `Sticker.deck_stack/1`'s sizer must stay a flex column with `max-h-full`, and `.deck-card` must keep `min-h-0`. Either one alone restores the overflow. A caller still must not add a card-height cap (D-047 §6).
- `ResultsComponents.mark_leaders/2` now runs for `:completed` as well as `:voting` and is `:cancelled`-exempt, because `presentable_tally/2` has already cleared those flags and re-computing would put the crown back on a session that says twice it was cancelled.
- `CoreComponents.check_your_email/1` takes `sent?`. Any future caller that can reach it without mailing anything must pass `false`, and must branch its own three slots — the component owns one line of the four that were false.
- `Layouts.app/1` and `Chrome.header/1` take `pill`. It is `:public`-only and there is exactly one caller passing `false`; a second one needs the same test shape, asserting what replaces the pill rather than just its absence.
- The border-box rule is now conditional. Before re-cutting a control to a frame's painted size, check whether a container dimension in `IMPORT-NOTES.md` depends on the current number — and record the re-cut in the entry that makes it, in D-041's table.
- 932 tests. `README.md`, `CLAUDE.md` and the `elixir` skill carry the count; they were reconciled to 922 by D-047 and moved together here.

---

## D-049 — Participation is public and choices are secret, said in those words; and a refused send is its own screen

**Date:** 2026-08-09
**Status:** settled

**Context.** The final fix pass before shipping, against what the consolidation sweep (D-046 → D-048) left when it hit its round cap. Two of the nine findings are regressions *introduced* by earlier fixes in that chain, which is the shape worth naming: a cap added in D-047 and a caption written in D-035 were each correct about the thing they were looking at and wrong about the screen they landed on.

### 1. Anonymity: what is actually true, and the five places that said otherwise

**Nothing about the app's behaviour changed. D-035 stands.** `Consensus.Voting` is structurally anonymous — `tally/1` returns per-option totals, there is no public function anywhere in the context that maps a participant to their approvals, and the PubSub message carries nothing about a ballot. What changed is that five sentences claimed more than that, and one of them claimed it on a screen that disproves it in the same render.

The two facts, and the order every one of these places now states them in:

> **Anyone with the link can see who has voted. Nobody sees what anyone picked — not even the organizer.**

Both halves are checkable. `ConsensusWeb.JoinLive.Results` renders the WHO'S VOTED row for `@participant == nil`, so `curl` with no cookies at all against `/join/:slug/results` returns `title="Sam"` and `<span class="sr-only">Sam</span>` — a visitor holding the share link reads the guest list without joining. And `Sticker.participant_avatar/1` puts the **full typed name** into `title` and into that `sr-only` span; only the visible glyph is the initial.

What was there, and why each was wrong:

- **`join_live/entry.ex`** — *"Just so {organizer} can see who has voted — your initial goes in the list, never next to what you picked."* Both halves of the first clause false, on the sentence that asks a stranger for their name. Not just the organizer, and not just the initial.
- **`results_components.ex`** — *"Anonymous session — totals only, no names."* Measured on one group: the element carrying `title="Sam"` at document y=170 and this sentence at y=969, same render. A screen-reader user hears "Sam, voted" and then, forty rows later, that there are no names. It is now scoped to the block it captions — *"Totals only — nothing here shows who picked what."*
- **`group_live/review.ex`'s anonymity card** — true but half. This is the last screen before an organizer hands the link out, so it is the last chance to tell them the link also exposes the guest list.
- **`/how-it-works`** — *"Votes are anonymous. Everyone sees the totals, never who picked what."* The second sentence true, the first over-claiming, on the page a reader opens to find out what is private.
- **`/privacy`** — the section was *headed* "Votes are anonymous" over a paragraph that now has to begin by saying the guest list is public. Retitled **"Who voted, and what they picked"**, and the "If you vote" section says where a typed name goes.

`HomeLive`'s splash card said a bare "Anonymous." and now says which half.

**The rule this leaves behind:** a privacy claim in this app names *who can see what*, never a single adjective. If a sixth place makes the claim, it says the sentence above.

### 2. `/users/log-in` had three outcomes and two states

D-047 gave the magic-link screen a per-mount send budget. `deliver_magic_link/2`'s refused clause assigned the same `@sent_to` its sending clause did, so a **new** address submitted past the cap rendered the full "Check your email" panel — `id="magic-link-sent"`, the heading, the spam-folder advice, and the never-mailed address. Driven against the real LiveView: `users_tokens where context = 'login'` 4 before and 4 after.

That is worse than the unbounded send it replaced, and the path that reaches it is the *designed* one: the screen's own "Use a different address" button goes back to the form, and someone who mistyped, corrected it and pressed send was told a link was on its way and would wait forever. The identical defect was found and fixed on `/users/settings` in D-048 §2; this is the same defect one screen over, and the fix there — an address plus a `refused?` flag — permits impossible combinations.

`@send_state` is **one** assign with exactly three values, and `deliver_magic_link/2` is its only writer:

| value | meaning | renders |
|---|---|---|
| `nil` | nothing submitted on this mount | the form |
| `{:sent, address}` | a token was minted and mailed | `#magic-link-sent`, "Check your email" |
| `{:refused, address}` | submitted past the budget; **nothing sent** | `#magic-link-not-sent`, "Nothing was sent" |

Addressable by `id`, so "did this page claim to have sent something?" is answerable without reading copy. `sent?={false}` also suppresses `check_your_email/1`'s dev-mailbox line, which is exactly as false as the spam-folder advice when no message exists.

**The enumeration property is preserved and is the reason the shape matters.** Which state is reached is a function of presses in *this browser*, never of the address; the refused clause does not call `Accounts.get_user_by_email/1` at all, so it cannot be timed either. Pinned by "the refused screen is byte-identical for a known and an unknown address" alongside the existing sent-screen twin.

The way out is one control with one label in every state — *"Use a different address, or log in with a password"* — a `phx-click` back to the form while there is budget, and a real HTTP `href` to `/users/log-in` once there is not, so the LiveView remounts and the budget is fresh. That is the "reload this page" the copy has always prescribed, made tappable; it costs an attacker exactly what a reload costs, so the cap is not weakened.

### 3. Both auth screens instructed a press they had just removed

With the budget spent, `/users/log-in` rendered `#magic-link-resend-exhausted` — "That's the last one we'll send from this page" — while the fallback paragraph above it still ended *"send it again, or use a different address"*, and the button between them was gone. `/users/register` had the same pair: `#registration-sent-resend-exhausted` reading "That is as many as we will send." directly under "Check the spam folder, then **send it again**". Both fallbacks branch on the same budget the button branches on now. Pinned on both screens by a test that asserts the **absence** of "send it again", because the failure is a sentence that should not be there.

### 4. The ballot's scroller was gated on a height real phones do not have

D-046 made `.viewport-column`'s clamp conditional on `min-height: 640px`, correctly — an unconditional `h-dvh` painted `#submit-ballot` over the footer in landscape. What it did not answer is where the submit button ends up **below** the gate, where the page is the scroller. Measured on a five-option pool at **375×553**, the iPhone SE / iPhone 8 Safari layout viewport: grid track 530px with `scrollHeight` 530 (nothing scrolling internally, as designed), `document.scrollHeight` 966, `#submit-ballot` ending at y=883.7 — **330.7px below the fold**, with `#ballot-status` below it again. The first screenful ended mid-pool.

The gate cannot simply be lowered. The chrome at 375 wide measures 436px (header 48 + view toggle 66 + heading 72.3 + submit block 191.4 + footer 58.3) and the track's `min-h-[200px]` floor puts a clamped column at 636px — 83px past the viewport, i.e. straight back to painting the button over the footer.

So the block sticks instead. `.ballot-actions` is `position: sticky; bottom: 0` with `--shadow-sheet`, written base-first and switched to `position: static` inside the **same** `@media (min-height: 640px)` the clamp uses, so the two ranges are complementary by construction. Measured after, at every scroll position: submit fully on screen and never overlapping the global footer at 375×553, 360×600 and **667×375** — landscape, which no threshold could ever have covered — and byte-for-byte unchanged above the gate (360×640: `position: static`, track 204.1, submit 497.8–557.8, footer top 581.8; 320×640 and 390×664 likewise).

`.results-actions` is the same rule on `ResultsComponents.results_panel/1`'s footer slot, for a simpler reason: **neither results screen asks for `fill_viewport` at all**, so the panel's own `overflow-y-auto` middle has nothing bounding it (`scrollHeight` 744 == `clientHeight` 744) and the page is the scroller at every height. It takes no opt-out. The panel's root `overflow-hidden` became `min-h-0` — it clipped nothing, and a non-visible overflow makes that box the scrollport a sticky descendant would stick inside.

### 5. A completed tie said both "Tied at the top" and "you have a winner"

D-048 §3 corrected the card and left the footer. `finished_headline/1` had no tie branch, so the same page read "Tied at the top" in the card at document y=263 and "Voting is closed and you have a winner." at y=1030. It takes the tally now, through a public `ResultsComponents.tie_at_top?/1` — presentation-only, exactly like `mark_leaders/2`: `Voting.tally/1` is untouched and one option still wins.

### 6. Smaller, and all of them measured

- **`/feedback`'s header `Log in` was the one control with no draft guard.** With 100 characters typed, every other escape carried `data-confirm` — the `‹`, all three standing links, both faces, the credit — and `#chrome-sign-in` carried `null`; clicking it and pressing Back returned an empty textarea. It takes `back_confirm` like its siblings, and the test asserts *no unguarded exit* (`header a:not([data-confirm])`) rather than a list, so the next control added cannot ship the way this one did.
- **`skip →` was an irreversible one-tap join 8px from the name field.** Measured at 360×640: the `<label>` wrapping `#display_name` ends at x=264.4, `skip →` starts at x=272.4, and the tap posts the join, mints the anonymous participant and navigates — after which `JoinLive.Entry` bounces anyone holding a token straight to the ballot, so there is no way back to retype. It carries a `data-confirm` armed only once something has been typed (trimmed — a blank name is normalised to `nil` anyway), the shape `leave_confirm/2` already uses, plus a hairline marking where the field stops.
- **Touch targets on `02b`.** `Remove` — which deletes the option — painted 47.8×18.8 with no `::before` at all: a 19px box, 43% of the minimum, on the destructive control. `Replace` and `Remove photo` were the only two controls in the app whose entire feedback state was `hover:` (`box-shadow: none`, no `active:`), so on touch they acknowledged a tap in no way at all, and both measured 32.5px tall. All three keep their painted size and gain the `before:absolute` expander: `Remove` at 63.75×43.94 with a 176-point `elementFromPoint` sweep resolving entirely to it, `Replace` 61.32×44, `Remove photo` 95.02×44, the pair growing vertically only because 6px of `gap-1.5` is all the horizontal clearance there is. `active:` beside every `hover:`.
- **Three tangerines on `/groups/:id/results`.** The winner card's `★` badge, the tally's `Vetoed` pill and `#results-start-another` — of which only the last can be pressed, and the rule is about the forward action. The badge is violet (the tally's own accent, matching the `★` on the winning row below it) and the pill is `--peach` (what the ballot's held veto already uses for the same state). Re-measured on a real completed session with a veto and a tie: exactly one visible tangerine element. `Sticker.tally_bar/1`'s doc argued for keeping the badge tangerine and is corrected in place.
- **The guest's forward action was a text link 268px below the fold.** `#results-start-your-own` on `/join/:slug/results` — the terminal screen of the flow this product exists for, and the screen the PRD's "guest drop-off under 5%" is measured on — was bare 12.5px violet text at y=1168 in a 900px viewport. It is a `<.button>` now, primary in every footer cell except `:can_vote`, where "Cast your vote" directly above already holds the screen's one tangerine.
- **`header_context/1` printed the violet band's own words.** It returned "RESULTS" / "CANCELLED" 47px above a band printing exactly those strings in the same DM Mono 10.5px uppercase — plan ruling 9 and D-041 forbid precisely that, and the function was *added* by the sweep that exists to remove such duplication. `nil` for both; `LIVE SESSION` stays, where the band says something else.
- **D-044 described an `<.eyebrow>View</.eyebrow>`** that D-046's sweep had deleted. Amended in place.

**Consequences:**

- **`ConsensusWeb.UserLive.Login`'s screen state is `@send_state`, one assign, three values.** A future control that can send from this screen goes through `deliver_magic_link/2` or it escapes both the cap and the honesty. Do not split it back into an address plus a flag.
- **`.ballot-actions` and `.viewport-column` are one fix in two rules and share a threshold**, asserted by reading `assets/css/app.css` as text in `ballot_test.exs` — the same technique `deploy_config_test.exs` uses on `fly.toml`, because nothing else in this suite can observe a media query. Changing one threshold fails there rather than leaving a band of viewports with neither mechanism.
- **`ResultsComponents.results_panel/1`'s root must not regain a non-visible `overflow`**, or `.results-actions` silently stops sticking.
- **`pill/1`'s `:tangerine` tone now has no caller in `lib/`.** Kept because the frames still specify it; do not reach for it on a screen that has a forward action.
- **One tangerine remains unresolved and is recorded rather than fixed:** a completed session whose winner carries a `source_url` renders `View {name} →` inside the winner card *and* `Start another session →`/`Create your own →` in the footer, both tangerine. Both are genuinely forward actions — one is PRD product invariant 5's booking CTA, the other the product's own next step — and picking between them is a product decision, not a colour cleanup. It was not reachable on the sessions measured here (their winners had no link).
- 944 tests. `README.md`, `CLAUDE.md` and the `elixir` skill carry the count and move with it.

## D-050 — Social previews: one static `og:image` for the whole app, per-group detail in the text, and no clock in the card

**Date:** 2026-08-09
**Status:** settled

**Context.** The product's entire distribution model is one link pasted into a group chat — `04 share` exists to produce it, `POST /join/:slug/enter` exists to receive whoever taps it, and PRD product invariant 1 (voter friction is zero) is measured on what happens next. Design frame `1d-0` (`docs/design/screens/1d-0-in-app-preview-paste-ready-copy.html`) draws that paste under the heading "HOW IT LOOKS IN CHAT": a card with an image band, the group's title, and the site name.

**The app emitted no `og:` tags at all.** Not a wrong card — no card. `root.html.heex` carried `charset`, `viewport`, `csrf-token`, `theme-color`, a `<title>` and a favicon, and nothing else; every paste of a Consensus link into Slack, iMessage, WhatsApp or a DM rendered as a bare blue URL. There was not even a `<meta name="description">`. The one screen in the app whose sole job is "send this link" promised a card the document could not produce.

**Decision.**

### 1. The image is one static asset, and per-group detail rides in the text

`og:image` is a single pre-rendered **1200×630** PNG for the whole app, `priv/static/images/og/consensus-og.png`, rendered from the "Consensus - Social Preview" file in the linked Claude Design project (`867b0685-278c-4ce4-ae2c-bce2135705af`) via headless Chrome at exact pixel dimensions. Two companion sizes from the same file ship beside it and are referenced by nothing: `consensus-square.png` (1200×1200, feed posts) and `consensus-story.png` (1080×1920, stories). They are marketing assets, checked in so the next person does not re-render them from a design file they have to find first.

The alternative was a `GET /join/:slug/og.png` that burns the group's title, spot count and deadline into the pixels. Rejected: it needs an SVG rasterizer in the release image and a cache, on the single Fly machine that already serialises every write behind one SQLite lock (invariant 15) — and it buys nothing a chat client does not already render, because **every unfurler draws `og:title` and `og:description` as text beside the image**, which is exactly where frame `1d-0` puts the group's own words. The frame's own chat card shows a plain gradient band with "Dinner Friday? · 5 spots" as text *below* it; the design had already made this decision and the implementation had only to read it.

`og:image` is emitted **absolute** (`Endpoint.url() <> ~p"..."`, the idiom `GroupLive.Share.join_url/1` already uses). A root-relative path is not resolved by unfurlers, it is dropped, and the card renders imageless — a failure that looks exactly like having shipped nothing. `og:image:width`/`:height` are declared because Facebook and LinkedIn otherwise render the first fetch as a thumbnail and only upgrade once their own crawler has measured the file. `twitter:card` is `summary_large_image`, which is what makes 1200×630 render full-bleed rather than as a 120px square.

### 2. The card carries no clock, on any screen

`06`'s pill and `04`'s invite card both say "closes thu 6pm" and it was tempting to repeat it in `og:description`. Two independent reasons not to, and either alone is sufficient:

- **There is no timezone on a dead render.** This app carries no timezone database (D-031); local time arrives as a `tz_offset` LiveView connect param, and **a crawler never opens a websocket**. The clock would be computed at UTC, so a Thursday 6pm ET deadline unfurls as "closes fri 10pm" — wrong, in the artifact whose whole job is to be trusted at a glance.
- **Unfurl caches are sticky and the tags are not live.** Slack, iMessage and WhatsApp cache a card for hours to days, keyed on the URL. A countdown written into that cache is wrong shortly after and cannot be corrected; the page itself is live over PubSub, and the card must not pretend to be.

The same rule kills the tally on `/join/:slug/results`: the card names the vote and its organizer, never the leader. A leader that changes with the next ballot would be pinned wrong in a cache with no way to correct it. **Anything that changes faster than a chat client's cache does not go in a meta tag.**

### 3. One component, defaults that make silence correct, and a canonical that drops the query

`ConsensusWeb.SocialPreview.meta_tags/1` renders the whole block and is called once, from `root.html.heex`, reading `assigns[:og_title]`, `assigns[:og_description]`, `assigns[:og_url]` and `assigns[:current_path]` by **bracket access** — the same layout renders for `HealthController` and the two error pages, none of which assign anything. Every attribute falls back to the app-wide card (the design's own "Decide and Dine" headline and sub-line, so the card's text and its image say the same thing), so a screen that says nothing still unfurls correctly, and a new screen inherits a correct card by doing nothing.

The canonical URL defaults to `@current_path` **with the query string stripped**. `ConsensusWeb.CurrentPath` deliberately keeps the query (the chrome's `?return_to=` depends on it), but every standing page is reachable as `/about?return_to=<wherever the footer was tapped>`, so honouring it would mint one canonical — and one sticky unfurl-cache entry — per originating screen for a page with a single identity.

Title and description are **clamped in the component** (70 and 200 characters, whitespace collapsed) rather than left to the platform. Group titles are free text and, per invariant 11, the changeset is the only length limit and it is generous; clamping here means the ellipsis lands where we chose and a pathological title cannot push the rest of the card out of the render.

Screens that set their own: `JoinLive.Entry` (frame `1d-0`'s shape verbatim — `"<title> · N spots"` over who called the vote and what answering costs), `JoinLive.Results`, and the four standing pages. `HomeLive` sets nothing on purpose — the app-wide default *is* the splash, and duplicating it would be two sources for one string.

**Consequences.**

- **`og:image` must stay absolute.** A relative path does not degrade, it disappears. Pinned by `social_preview_test.exs`, which asserts the tag matches `image_url/0` and starts with a scheme.
- **The tags exist only on the dead render**, which is correct and load-bearing: no crawler opens a websocket, so a LiveView assigning them in `mount/3` is sufficient and none of them need to survive a `live_patch`. A future screen that sets `og_title` from `handle_params` alone would be invisible to every unfurler.
- **`social_preview_test.exs` asserts the image is actually served** (`GET` on the path from `image_url/0` returns 200 and `image/png`), because a meta tag pointing at a 404 is the failure mode that leaves the whole feature looking shipped. It also pins the tags route by route rather than only as a component — the component can be perfectly correct while no screen passes it anything, which is the same reason `chrome_test.exs` tests both halves.
- **Nothing added `noindex`, and the join slug is still a capability URL.** Making a share link unfurl and making it uncrawlable are opposite pressures — `facebookexternalhit` and `Twitterbot` read `robots.txt`, so the obvious defence also suppresses the previews this entry exists to add. Whether `/join/:slug` should be excluded from search engines, and by what mechanism, is a real question and is **not** answered here; it is recorded in `open-questions.md` as F-9.
- **The render is reproducible, checked in, and deterministic.** `bash docs/design/social-preview/render.sh` rewrites all three PNGs from the three transcribed HTML panels beside it; re-running it against an unchanged source produces byte-identical files, which is what makes an accidental re-render a no-op in `git status` rather than a diff nobody can review. It is a script rather than a mix task on purpose — it needs Chrome and the network, so it must not sit anywhere `mix precommit` or CI could reach it. The icon is read from `priv/static/images/icon.svg` at render time rather than duplicated, and inlined as a `data:` URI because Chrome refuses `file://` subresources. Re-render only when the design file changes, and re-check the `og:image:width`/`:height` pair if an aspect ratio does.
- 964 tests. `README.md`, `CLAUDE.md` and the `elixir` skill carry the count and move with it.

---

## Still open

D-003 answers Q-1, Q-2 and Q-3 in [open-questions.md](open-questions.md).

**The voting engine is no longer untouched.** D-034 through D-037, plus the `participants` / `votes` migration and `Consensus.Voting`, settle the schema questions (Q-9, Q-10, Q-11 — the two candidate vote schemas, the missing `participants` table, and whether `users` exists) and most of veto semantics (Q-8): one veto per participant, instant elimination, no withdrawal because the ballot is locked (D-036), anonymous like every other mark (D-035), and `outcome/1` reporting `:no_consensus` rather than crowning something the group struck out (D-034). Q-8's remaining bullet is the **veto floor** — nothing stops vetoes eliminating every option, and whether that should be blocked at ≤2 survivors is still open. Q-4 (guest identity) is answered on **both** sides now: a 32-byte server-minted `participants.token` in storage, never castable, and on the transport side a `"participant_token:<group_id>"` key in the session written by `ConsensusWeb.JoinController` and deliberately preserved across `UserAuth.renew_session/2` (D-045). ~~Open on the transport side, because the cookie/session half belongs to the `/join` web layer, which is not built.~~ That clause was true when it was written and the `/join` tree has since shipped.

Still undecided: the veto floor (Q-8), booking deep-links (Q-5), the Places/Yelp provider and its caching terms (Q-6), winner delivery (Q-7), the remaining sessions/options field ambiguities (Q-12), and the whole non-blocking set (Q-13 through Q-16).

~~One smaller item is deliberately deferred rather than open: this app ships with **no production mail *provider***, only the Logger adapter that D-014 pins in its place. Choosing that provider is the open part; shipping without one was the decision.~~ **Closed by D-039**: the provider is **Resend**, wired in `config/runtime.exs` and active whenever `RESEND_API_KEY` is set, with `Swoosh.Adapters.Logger` as a loud boot-time fallback when it is not. What survives of the paragraph is the operational caveat, and it is a deployment fact rather than an open decision: until that secret and a `MAIL_FROM` on a Resend-verified domain exist, magic-link log-in and the confirm-your-email-change flow reach nobody in production. `fly secrets list` answers whether they do; this file cannot. Registration is unaffected either way — it takes a password and signs the new account in immediately (D-004), so nobody is ever blocked waiting on an email.
