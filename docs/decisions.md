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
- **Status:** settled
- **Decision:** `ConsensusWeb.Layouts.app/1` renders the canvas, a centred column and the flash group — nothing else. Every screen draws its own header. `Layouts.account_menu/1` is a `<details>`-based avatar menu that screens place themselves, and `Layouts.avatar/1` renders the user's initial.

**Why:** the design gives each screen a different header, and each difference carries meaning. The home screen has a wordmark and an avatar; the wizard steps have a back button and a three-segment progress bar; the option editor has a close button and a destructive `Remove`. A shared bar above all of them would either duplicate the back affordance or push the progress bar down a row — and on a 390px phone there is no row to spare.

A `<details>` element rather than a JS dropdown so the menu works before LiveView connects, closes on Escape, and needs no code of ours.

**Alternatives rejected:**
- *One navbar with per-screen slots.* That is a header component with an empty shell around it; the shell adds a layout constraint and no shared behaviour.
- *Keep the generator's navbar on non-wizard screens only.* Two visual languages depending on where you are, which is exactly what the design avoids.

**Consequences:**
- D-024 is superseded — the element it describes is gone.
- Every new screen owes its own header, including a way back. A screen with no way out is now a review finding, not something the layout catches.
- The desktop console reuses `Layouts.app/1` with `width={:wide}` rather than a second layout.

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
- **Decision:** `Consensus.Voting.cast_ballot/3` does **every** pure and read-only check — id casting, ballot shape, participant re-read, group status, deadline, veto permission, "is this activity even in this group" — *before* `Repo.transact/1` opens. Inside the transaction there are exactly three statements: a primary-key re-read of the group, the conditional `UPDATE participants SET voted_at = ? WHERE id = ? AND voted_at IS NULL`, and one `Repo.insert_all/3` for every vote row. Both voter-facing entry points (`cast_ballot/3` and `create_participant/2`) `rescue` **`Exqlite.Error` and `DBConnection.ConnectionError`** into `{:error, {:database_busy, message}}`, and `cast_ballot/3` wraps itself in a bounded, jittered retry (`@busy_retries 2`, `@busy_retry_pause_ms 25..150`) before giving up. `ensure_all_in_group/2` bounds the client's id list by the group's own activity count before building an `IN (?, ?, …)`, and `outcome/1` reports `:no_consensus` when every option has been vetoed rather than leaving a completed group with no winner and no leader.

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
- `outcome/1` exists because `tally/1` alone cannot distinguish "everybody vetoed everything" from "nobody has voted yet" — both are a list with no `leader?` and no `winner?`. There is deliberately **no** fallback to the least-vetoed option: "everyone gets one veto, vetoed places drop out" is the rule the organizer showed the group.
- [test/consensus/voting_concurrency_test.exs](../test/consensus/voting_concurrency_test.exs) is the regression guard, and it is the only case in the suite that executes two ballots at the same instant — see its moduledoc for what it does and does not discriminate.

---

## D-035 — MVP voting is unconditionally anonymous; the review screen states the rule instead of offering a switch

- **Date:** 2026-08-08
- **Status:** settled
- **Decision:** `Consensus.Voting` is **structurally** anonymous in every mode: `tally/1` returns totals only, `participants/1` returns name/initial and *whether* someone voted, the PubSub message is `{:ballot_cast, group_id}` and carries nothing about the ballot, and there is no public function anywhere in the context that maps a participant to the options they approved. `Consensus.Activities.Group.anonymous` stays in the schema (default `true`) but nothing reads it. `ConsensusWeb.GroupLive.Review` no longer renders a toggle for it — the card states the rule ("Nobody sees who picked what — totals only", `ALWAYS ON`) the way the veto card states its rule.

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

## Still open

D-003 answers Q-1, Q-2 and Q-3 in [open-questions.md](open-questions.md).

**The voting engine is no longer untouched.** D-034 through D-037, plus the `participants` / `votes` migration and `Consensus.Voting`, settle the schema questions (Q-9, Q-10, Q-11 — the two candidate vote schemas, the missing `participants` table, and whether `users` exists) and most of veto semantics (Q-8): one veto per participant, instant elimination, no withdrawal because the ballot is locked (D-036), anonymous like every other mark (D-035), and `outcome/1` reporting `:no_consensus` rather than crowning something the group struck out (D-034). Q-8's remaining bullet is the **veto floor** — nothing stops vetoes eliminating every option, and whether that should be blocked at ≤2 survivors is still open. Q-4 (guest identity) is answered on the storage side — a 32-byte server-minted `participants.token`, never castable — and open on the transport side, because the cookie/session half of it belongs to the `/join` web layer, which is not built.

Still undecided: the veto floor (Q-8), booking deep-links (Q-5), the Places/Yelp provider and its caching terms (Q-6), winner delivery (Q-7), the remaining sessions/options field ambiguities (Q-12), and the whole non-blocking set (Q-13 through Q-16).

One smaller item is deliberately deferred rather than open: this app ships with **no production mail *provider***, only the Logger adapter that D-014 pins in its place — registration takes a password and signs the new account in immediately (D-004), so nobody is ever blocked waiting on an email. The cost is that magic-link log-in and the confirm-your-email-change flow reach nobody in production until a provider is configured in `config/runtime.exs`. Choosing that provider is the open part; shipping without one was the decision.
