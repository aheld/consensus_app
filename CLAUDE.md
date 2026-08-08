# Consensus

Consensus is a Phoenix 1.8 / LiveView 1.2 application on Elixir 1.20 and SQLite, deployed to Fly.io as a single machine with the database on a mounted volume. What exists today is the **foundation**: username-or-email authentication (`mix phx.gen.auth` with 1.8 scopes, extended with `username` and `is_admin`), an admin area (user list with promote/demote/delete, an editable home-page message, LiveDashboard), first-boot seeding of a bootstrap admin, and a CI → Fly deploy pipeline. The product destination — a zero-friction group activity-voting PWA — is described in `docs/PRD.md` and is **not built yet**; none of it exists in `lib/`.

## Read first

| Doc | Authority |
|---|---|
| [AGENTS.md](AGENTS.md) | **How to write code here.** Official Phoenix/LiveView/Ecto/HEEx usage rules injected by `phx.gen.auth`, plus a short Consensus-specific appendix. Read before touching `lib/`. This file does not restate it. |
| [docs/decisions.md](docs/decisions.md) | **North star for technical.** ADR-lite log, currently D-001 through D-026. Anything recorded here beats the drafts. |
| [docs/PRD.md](docs/PRD.md) | **North star for product.** Personas, functional requirements, success metrics. Ratified. Contains no stack, schema, vendor, or algorithm decisions — by design. |
| [docs/open-questions.md](docs/open-questions.md) | What still needs a product/technical decision. |
| [docs/technical-roadmap-v1-draft.md](docs/technical-roadmap-v1-draft.md) | **Not ratified.** First-pass stack proposal (NestJS/Socket.io/Redis). Reference only — do not implement from it. |
| [docs/prd-technical-extracts.md](docs/prd-technical-extracts.md) | **Not ratified.** Technical content removed from PRD v2.0, kept as a second candidate. Contradicts the roadmap draft in places. Reference only. |

Authority order: `decisions.md` > `PRD.md` > the two unratified drafts. If a draft and `decisions.md` disagree, `decisions.md` is correct.

**Caveat that matters right now:** `decisions.md` now records the foundation as D-003 through D-026 — stack, auth, authorization, migrations-at-boot, seeding, the Fly single-machine trade-off, the mailer, magic-link account recovery, the boot-time volume preflight, the depth of the `/health` check, snapshot restore, the default home-page message, sudo mode on the two admin writes, the WAL-set preflight, the `PHX_HOST` = `<app>.fly.dev` rule, the navbar `min-w-0` fix, and the deliberately absent `maxlength`. Read it front to back before assuming anything, and note the supersession chain on one subject: **D-015 superseded the second half of D-005**, and **D-017 then superseded the second half of D-015**. The end state is the only one to quote — a magic link on an unconfirmed account that holds a password confirms it, logs the person in, and discards the password *unconditionally*; `Accounts.login_user_by_magic_link/1` is back to the generator's arity and takes no session argument. `open-questions.md` has caught up — Q-1, Q-2 and Q-3 were deleted from it once D-003 answered them, and the file says so in its own header. It now opens with an `F-` section recording **known gaps in code that has already shipped** (the untested new-migration-against-real-rows path, the fact that nothing has ever actually been deployed to Fly, the absent mail provider, and two guards that pass vacuously in environments unlike this one). Read that section before assuming a gap is undiscovered; the `Q-` numbers below it are voting-engine product questions and are genuinely open. When you settle something, append it to `decisions.md` and strike the corresponding open question.

**Keep the separation clean.** Product docs say what and why; technical docs say how. Don't reintroduce a vendor name, table definition, framework, or algorithm into the PRD — put it in `decisions.md` (settled) or `open-questions.md` (not).

## Skills

Four skills live in [.claude/skills/](.claude/skills/). Each is written against *this* repo, not generic docs.

| Skill | Use it when |
|---|---|
| `phoenix` | Editing anything under `lib/consensus_web/` — a LiveView, route, component, template, or LiveView test. Covers `Layouts.app` + `root.html.heex` (there is no `app.html.heex` in 1.8), HEEx `{}` vs `<%= %>`, the LiveView lifecycle, `live_session`/`on_mount`, `@current_scope`, `~p` verified routes, PubSub, `Phoenix.LiveViewTest`. |
| `elixir` | Mix tasks, adding a child to the supervision tree in `Consensus.Application`, Ecto changesets and context functions, ExUnit with `DataCase`/`ConnCase` and the sandbox, decoding compiler warnings and `--warnings-as-errors` failures, IEx debugging. |
| `sqlite` | Writing a migration SQLite might reject (`ALTER COLUMN`, `ADD CONSTRAINT`, adding a `NOT NULL` column), inspecting the DB with the `sqlite3` CLI, resetting or backing it up, or diagnosing `** (Exqlite.Error) database is locked`. |
| `fly-io` | Deploying, rolling back, reading production logs, provisioning or restoring the volume, setting `fly secrets`, editing `fly.toml` or the `Dockerfile` for production, or debugging a missing `SECRET_KEY_BASE`, migrations that did not run, or a broken production websocket. |

`.claude/agents/` exists but is empty. `.claude/launch.json` defines one dev-server config, `consensus-dev` (`mix phx.server`, port 4000).

## Repo layout

```
/
├── CLAUDE.md                     # this file — repo map, invariants, workflows
├── AGENTS.md                     # how to write Phoenix/Elixir code (do not duplicate here)
├── README.md                     # written for this app: status, bootstrap-password warning, setup
├── TODO.md                       # first-deploy checklist + troubleshooting (app.ex and fly.toml cite it)
├── mix.exs / mix.lock
├── Dockerfile                    # generator output + one added block: mkdir/chown /data
│                                 #   (no `VOLUME /data` — removed on purpose, see invariants)
├── fly.toml                      # one machine, one volume, an http_service health check,
│                                 #   deliberately no [deploy]. Its header says `app` and
│                                 #   PHX_HOST must agree; that is now machine-checked by
│                                 #   test/consensus/deploy_config_test.exs (D-023).
├── .github/workflows/
│   ├── ci.yml                    # deps check, format, warnings-as-errors, test, then a
│   │                             #   `docker` job: build, boot + smoke test, and boot twice
│   │                             #   on one volume (see invariant 10)
│   │                             #   on: pull_request + workflow_call ONLY — never push
│   └── fly-deploy.yml            # on push to main: calls ci.yml, then
│                                 #   flyctl deploy --remote-only --ha=false
├── .claude/
│   ├── skills/{phoenix,elixir,sqlite,fly-io}/SKILL.md
│   ├── agents/                   # empty
│   ├── launch.json
│   └── settings.json, settings.local.json
├── config/                       # config, dev, test, prod, runtime
├── lib/
│   ├── consensus/                # domain
│   │   ├── accounts.ex           # the Accounts context
│   │   ├── accounts/{user,user_token,user_notifier,scope}.ex
│   │   ├── content.ex            # admin-editable site content + PubSub broadcast
│   │   ├── content/home_page.ex  # singleton row, id = 1 (DB CHECK constraint)
│   │   ├── application.ex        # supervision tree (public children/0), skip_migrations?/skip_seeds?
│   │   ├── boot_check.ex         # volume/DATABASE_PATH + WAL-set preflight, before Consensus.Repo
│   │   ├── seeds.ex              # the ONLY seeding module
│   │   ├── release.ex            # migrate/0, seed/0, rollback/2 (mix-free); all three preflight
│   │   ├── repo.ex, mailer.ex
│   ├── consensus_web/
│   │   ├── router.ex             # pipelines, scopes, live_sessions
│   │   ├── user_auth.ex          # plugs + on_mount hooks + log_in/log_out
│   │   ├── endpoint.ex, telemetry.ex, gettext.ex
│   │   ├── components/{core_components,layouts}.ex, components/layouts/root.html.heex
│   │   │                         #   layouts.ex's navbar right-hand group is
│   │   │                         #   `<div id="user-nav" class="min-w-0">` — the id and the
│   │   │                         #   min-w-0 are both asserted; see D-024
│   │   ├── controllers/user_session_controller.ex   # + health_controller.ex (GET /health,
│   │   │                                            #   outside :browser, force_ssl-excluded)
│   │   └── live/
│   │       ├── home_live.ex                  # public "/"
│   │       ├── admin_live/{users,home_page}.ex
│   │       └── user_live/{registration,login,confirmation,settings}.ex
│   └── consensus.ex
├── priv/repo/migrations/         # users+auth tables, home_page
├── priv/repo/seeds.exs           # calls Consensus.Seeds.run!/0
├── rel/overlays/bin/             # server, migrate (+ .bat pairs; migrate is unused — see invariants)
├── test/                         # 323 tests; support/ has ConnCase, DataCase, fixtures
│   ├── consensus/                # accounts, accounts/user_notifier, content, seeds,
│   │                             #   application, boot_check, release — the last three cover
│   │                             #   the boot path no request-level test reaches.
│   │                             #   release_test.exs migrates a throwaway repo under its own
│   │                             #   tmp_dir, never the suite database; its "the boot preflight"
│   │                             #   describe pins that all three entry points preflight.
│   │                             #   deploy_config_test.exs reads fly.toml as text (no database)
│   │                             #   and asserts its stanzas agree with each other — `app` vs
│   │                             #   PHX_HOST, PORT vs internal_port, DATABASE_PATH inside the
│   │                             #   mount, and the single-quoted shape ci.yml's sed expects.
│   └── consensus_web/            # router_test.exs asserts BOTH admin guards on every /admin
│                                 #   route; user_auth_test.exs covers require_admin_user/2
│                                 #   and on_mount :require_admin; controllers/ adds
│                                 #   health_controller_test.exs (async: false — see AGENTS.md)
├── assets/                       # app.css (Tailwind v4), app.js, vendor/
└── docs/
    ├── PRD.md, decisions.md, open-questions.md
    ├── technical-roadmap-v1-draft.md, prd-technical-extracts.md
    └── plans/                    # per-feature implementation plans
```

**Note:** only ten files are tracked in git — `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `README.md`, and the six `docs/` files. All of `lib/`, `config/`, `test/`, `priv/`, `mix.exs`, `Dockerfile`, `fly.toml`, `.github/`, `rel/`, `assets/`, `.claude/skills/`, `TODO.md` and `AGENTS.md` are **untracked**. Verify with `git ls-files` before writing anything that assumes a clean history.

## Engineering invariants

Derived from the code. Breaking one of these is a regression even if the tests still pass.

1. **Authorization is enforced in three places, and all three must stay.**
   - Router pipeline: `pipe_through [:browser, :require_authenticated_user, :require_admin_user]` on both `/admin` scopes ([lib/consensus_web/router.ex](lib/consensus_web/router.ex)).
   - LiveView mount: `live_session :require_admin, on_mount: [{ConsensusWeb.UserAuth, :require_admin}]`. Plug pipelines do not run for the LiveView websocket connection, so the plug alone is not a guard. LiveDashboard declares its own `live_session` and therefore takes the hook directly.
   - The context: `Consensus.Content.update_home_page/2` pattern-matches `%Scope{user: %User{is_admin: true}}` in the function head. A non-admin caller raises `FunctionClauseError` rather than silently writing. Authorization there is a precondition, not a runtime branch — keep it that way for any new write function.

   [test/consensus_web/router_test.exs](test/consensus_web/router_test.exs) asserts the first two on every `/admin` route; `Phoenix.Router.__routes__/0` does not expose `pipe_through`, so the plug half is asserted against the router source.

   **Every admin write also re-reads the actor's role from the database, because the `%Scope{}` in hand can be stale.** A LiveView holds the scope it mounted with, so an admin demoted a moment ago must not keep acting from a tab they already had open — matching `%User{is_admin: true}` in the head only proves what was true at mount. Three functions do this, in two shapes:
   - `Accounts.set_admin/3` and `Accounts.delete_user/2` call `ensure_actor_is_admin/1` on the actor id **inside `Repo.transact`**, so the check and the write see one snapshot. Both are destructive, and for `set_admin/3` the last-admin count must not race the write. Both then call `ensure_actor_in_sudo_mode/1` in the same `with` — see invariant 5.
   - `Content.update_home_page/2` re-reads with `Accounts.get_user/1` after the head match and returns `{:error, :unauthorized}` for a revoked admin. No transaction: it is a single non-destructive `Repo.update` on one row, and there is no count to keep consistent. It carries **no** sudo requirement — editing prose is not granting or destroying authority.

   Either shape is acceptable for a new write; skipping the re-read is not.

2. **Seeding is idempotent, gated on there being zero admins, and lives in exactly one module.** `Consensus.Seeds.run!/0` is the only implementation; the three callers ([lib/consensus/application.ex](lib/consensus/application.ex) as a supervision child, [priv/repo/seeds.exs](priv/repo/seeds.exs), and `Consensus.Release.seed/0`) all delegate to it. The gate is `Accounts.count_admins() > 0 → do nothing` and `run!/0` then returns `admin: nil`; it checks the *role*, not the username, so renaming the bootstrap account does not make the next boot recreate it. It never modifies an existing user — if someone changed the bootstrap admin's password or revoked its role, that stands. The `{Consensus.Seeds, skip: skip_seeds?()}` child **must stay directly after `{Ecto.Migrator, ...}`**: both run synchronously during supervisor init and return `:ignore`, so the schema is current and the admin exists before `ConsensusWeb.Endpoint` accepts traffic. `config/test.exs` pins `seed_on_boot: false` so the suite is never seeded behind ExUnit's back.

   That ordering is now asserted, the way invariant 1 asserts the router: [test/consensus/application_test.exs](test/consensus/application_test.exs) reads the public `Consensus.Application.children/0` and asserts that both children are present, that the `Consensus.Seeds` index is exactly one greater than the migrator's, and that both precede `ConsensusWeb.Endpoint`. It also asserts `seed_on_boot` is `false` in test. Before that file existed, deleting either child, reordering them, or inverting `skip_migrations?/0` left the whole suite green.

3. **`fly.toml` must never gain a `[deploy] release_command`.** A Fly release machine has no volume mounted, so a release command would migrate a throwaway database and leave the real one untouched. Migrations run at boot through the `{Ecto.Migrator, repos: ..., skip: skip_migrations?()}` child, gated on `RELEASE_NAME`. `rel/overlays/bin/migrate` exists (generator output) but is not part of the deploy path. Reference: <https://fly.io/docs/elixir/advanced-guides/sqlite3/>. Because that child is the *only* migration path, its presence and position are now asserted structurally rather than inferred — `Consensus.Application.children/0` is public for exactly that reason (see invariant 2) and must not be re-privatised.

   Ahead of all of it, `Consensus.Application.start/2` calls a private `preflight!/0` — in a release only, on the same `skip_migrations?/0` gate — which delegates to **`Consensus.BootCheck.run!/0`** ([lib/consensus/boot_check.ex](lib/consensus/boot_check.ex)), before `Consensus.Repo` enters the tree. It does three things:
   - creates `Path.dirname(DATABASE_PATH)` if it is missing, then writes and removes a probe file there;
   - opens **every existing member of the WAL set** for `:append` — `DATABASE_PATH` itself plus `<path>-wal` and `<path>-shm`, filtered through `File.exists?/1` so a first boot (none of them present) and a cleanly checkpointed database (sidecars gone) both pass. `journal_mode: :wal` is pinned in `config/runtime.exs`, so SQLite must write all three and cannot start without them; their ownership can differ from the database's, and a `DATABASE_PATH`-only probe walks straight past that. It is **not** enough to probe the directory either — that misses a file inside a writable directory that belongs to root;
   - compares the directory's device id against `/` (`BootCheck.on_root_filesystem?/1`) and, when they match, **raises if `FLY_APP_NAME` is set** and logs a `Logger.warning` otherwise.

   The first two failures raise `Cannot write the SQLite database (<reason>)` and name **the path that actually refused** on a `refused       : <path>` line, followed by `DATABASE_PATH`, the directory, every member of the WAL set with its uid/gid/mode, the release user (`nobody`, uid 65534) and the fix (`fly ssh console -u root -C "chown -R 65534:0 /data"`). Report the refused path, not `DATABASE_PATH` — a root-owned `-wal` beside a perfectly healthy `consensus.db` is the whole point of the line. The third raises or logs `<dir> is not a mount point — it is part of the container filesystem.` — grep production logs for `is not a mount point` and for `refused       :`, not for any older wording. Raising rather than warning on Fly is deliberate: the database is empty by definition at that point, so failing the deploy costs nothing and beats discovering it after the next deploy destroys the data. The warn-only path is retained off Fly so a quick `docker run` with no `-v` still works.

   **All three `Consensus.Release` entry points — `migrate/0`, `seed/0` *and* `rollback/2` — call `BootCheck.run!/1` on the configured database.** They execute in a fresh node via `bin/consensus eval`, which never goes through `Consensus.Application.start/2`, and they are exactly what an operator reaches for when something is already wrong — without the preflight they report an unwritable volume as a connection-pool error. `rollback/2` used to be exempt; it no longer is, and it is the entry point *most* likely to be typed into a broken machine. Pinned by the `"the boot preflight"` describe in [test/consensus/release_test.exs](test/consensus/release_test.exs) — do not re-exempt any of the three.

   Verified: with a root-owned volume the release dies with that message instead of eleven `database_open_failed` lines and a misleading `DBConnection.ConnectionError` about connection pools. The `Dockerfile`'s `RUN mkdir -p /data && chown nobody:root /data && chmod 750 /data` only helps when the mount is empty, which is why the preflight exists. There is deliberately **no `VOLUME /data`** in the Dockerfile: it made `docker run` with no `-v` invent an anonymous volume and look durable. A local run without `-v` now honestly loses its data. Removing `VOLUME` is not what makes that *visible*, though — `RUN mkdir -p /data` means `/data` is writable either way, so the app would boot clean and seed onto ephemeral storage. The mount check above is what says so. Keep every part. Regression guard: [test/consensus/boot_check_test.exs](test/consensus/boot_check_test.exs) exercises all of it against real directories under a `tmp_dir`, and pins the exact wording of `Cannot write the SQLite database`, `refused       : <path>` (once for the database and once for a root-owned sidecar), `is not a mount point`, `destroyed by the next deploy`, `fly volumes list` and the `chown -R 65534:0 /data` line.

4. **Never scale past one machine.** One machine mounts one volume, and SQLite is a file on that volume — a second machine gets a different database or none. `flyctl deploy --remote-only --ha=false` in [.github/workflows/fly-deploy.yml](.github/workflows/fly-deploy.yml) is what enforces this at deploy time; never run `fly scale count 2`. `auto_stop_machines = 'off'`, `auto_start_machines = false` and `min_machines_running = 1` are a set: a stopped machine drops every LiveView websocket and takes the database offline, and auto-stop with auto-start disabled means it never comes back. A `[[http_service.checks]]` block (`GET /health`, `grace_period = '15s'`, `interval = '30s'`, `timeout = '5s'`) watches the machine after the deploy's ~10s smoke window closes. It must stay on `/health`, not `/`: Fly's checker connects over plain HTTP to the machine's private address, and `force_ssl` in `config/prod.exs` 301-redirects everything not on its exclusion list — `/health` is on that list (see invariant 10 for what the endpoint actually proves).

   **`fly.toml`'s stanzas must also agree with each other, and three of those agreements are now asserted** by [test/consensus/deploy_config_test.exs](test/consensus/deploy_config_test.exs) (no database, runs in milliseconds, fails on a pull request): `PHX_HOST` must equal `<app>.fly.dev`, `PORT` must equal `internal_port`, and `DATABASE_PATH` must sit inside `[[mounts]] destination`. The `PHX_HOST` one is the expensive mistake — `check_origin` defaults to `true` in prod and validates `Origin` against the endpoint's `:url` host, which `config/runtime.exs` takes from `PHX_HOST`, so a mismatch 403s every LiveView socket while `GET /` and `/health` both keep answering 200 and Fly reports the machine healthy (D-023). A fourth test pins `PHX_HOST` as a *single-quoted* scalar, because `ci.yml`'s `sed` expression depends on that shape. If this app ever moves to a custom domain, **edit** that first test and record the move in `decisions.md` — do not delete it.

   Recovery from a lost or corrupted volume is [TODO.md](TODO.md) §7, "Restoring from a snapshot" (steps R1–R8), and that procedure **necessarily destroys and recreates the Machine**: a mount is bound to a volume *ID* fixed when the Machine was created, not to the `[[mounts]] source` name `consensus_data`, so neither `fly deploy` nor `fly apps restart` can re-point an existing Machine at a restored volume, and creating a new volume with the same name does not reattach it (D-019). The procedure is documented but has never been executed against a live app.

5. **The last admin cannot be demoted, an admin cannot be deleted without first being demoted, and both writes require sudo mode.** `Consensus.Accounts.set_admin/3` — note the arity; it takes the **actor's `%Scope{}` first** — runs inside `Repo.transact`, re-reads both the actor and the target (the caller's structs may be stale), and returns `{:error, :last_admin}` when `count_admins() <= 1`. The check and the write must see the same snapshot. It returns `{:ok, {user, tokens_to_disconnect}}`; the caller **must** hand those tokens to `ConsensusWeb.UserAuth.disconnect_sessions/1` (it does, in the private `ConsensusWeb.AdminLive.Users.set_admin/3` helper), which is how a demoted admin's already-mounted LiveView is cut off rather than left holding its old scope.

   **`delete_user/2` has exactly the same shape, and this is a change from what this file used to say.** It returns `{:ok, {user, tokens_to_disconnect}}` too — collected *before* the row is deleted, since `ON DELETE CASCADE` takes them with it — and `AdminLive.Users` calls `disconnect_sessions/1` on the delete branch as well. Do not restore the old claim that "the delete path does not disconnect at all": it was true once, and the reason it was tolerable (`delete_user/2` refuses to delete an administrator, so the stale socket was never a privileged one) was always thin. A deleted person is now cut off promptly rather than left running a LiveView on a scope with no account behind it.

   **Both writes additionally require the actor to be in sudo mode** — `ensure_actor_in_sudo_mode/1`, i.e. `Accounts.sudo_mode?/1`, whose default window is `@sudo_mode_minutes 20` in `Consensus.Accounts`. Out of the window, both return `{:error, :sudo_required}` and write nothing. Note the two windows differ deliberately and both are real: `/users/settings` uses **10** minutes (`on_mount(:require_sudo_mode, ...)` passes `-10` explicitly in `ConsensusWeb.UserAuth`), the two admin writes use **20**. `ConsensusWeb.AdminLive.Users` routes `:sudo_required` through its private `require_sudo/2`, which flashes and `push_navigate`s to `/users/log-in`, and it renders `<div :if={!@sudo?} id="sudo-notice">` plus `disabled={!@sudo?}` on Promote, Demote and Delete. **The UI disabling is a courtesy, not the enforcement** — a `disabled` attribute is a client-side hint and the event can be pushed anyway; `Consensus.Accounts` is the only thing that actually refuses. Removing the sudo gate from the context while leaving the notice in place would leave the suite's other assertions green and the app unprotected. See D-021.

   **Both writes also emit a private `audit/4` Logger line, and it must not be removed.** `[audit] <action> actor_id=… actor=… target_id=… target=…` at `:info` on success, `[audit] <action> REFUSED <reason> …` at `:warning` on every refusal, where `<action>` is `grant_admin`, `revoke_admin` or `delete_user`. Ids come first because usernames are mutable, and nothing password-derived is ever logged. This deployment has one machine, no external audit sink and no undo, so this line is the only record of who promoted or deleted whom — and a burst of `REFUSED :unauthorized` is exactly what an attempt to act from a revoked session looks like. `audit/4` returns its input unchanged; keep it that way.

   **The `disconnect_sessions/1` call on the demotion branch is not redundant with the in-transaction actor re-read, and deleting it used to leave the suite green.** `ensure_actor_is_admin/1` protects only *our* write paths — a caller that reaches a context function. A mounted LiveDashboard has no context to re-read and no authorization of its own (D-011): its `:require_admin` `on_mount` hook runs once, at mount, and `live_patch` between dashboard pages inside the same `live_session` does not remount. `disconnect_sessions/1` is therefore its *only* revocation. It is now pinned by "demoting severs the demoted admin's live sockets" in [test/consensus_web/live/admin_live/users_test.exs](test/consensus_web/live/admin_live/users_test.exs).

   One precision point, because the obvious reading of "disconnect" is wrong on the demotion side:
   - **Demotion does not log anyone out.** `set_admin/3` *collects* the target's session tokens (`Repo.all_by(UserToken, user_id: ..., context: "session")`) but does not delete them, unlike `update_user_and_delete_all_tokens/1`. The demoted admin stays signed in as an ordinary member; the broadcast only forces a remount, and it is the remount re-running the `:require_admin` hook that turns them away. Deletion is the opposite case — the tokens are gone with the row by cascade, and the broadcast is what stops the already-open socket.

   `Consensus.Accounts.delete_user/2` is the sibling recovery lever (D-015): it refuses to delete an administrator (`{:error, :is_admin}`) and refuses self-deletion (`{:error, :self}`), and deleting frees the email address and username. Session tokens cascade; `home_page.updated_by_id` is nulled. `ConsensusWeb.AdminLive.Users` surfaces every one of these as a flash, not a crash. Both writes also `rescue Exqlite.Error` into `{:error, {:database_busy, _}}` — SQLite raises rather than returning a tuple when a write cannot take the lock, and that is not worth crashing a LiveView over.

6. **Registration can never set `is_admin`.** `User.registration_changeset/3` casts exactly `[:email, :username, :password]`, and `Accounts.register_user/1` is the only thing behind the public form. `User.admin_changeset/2` casts exactly `[:is_admin]` so an admin-only endpoint cannot smuggle an email/username/password change through it. Exactly two things can set the role: `Accounts.create_user/2`, which adds a second `cast(attrs, [:is_admin, :confirmed_at])` on top of the registration changeset and whose only caller is `Consensus.Seeds`; and `admin_changeset/2`, reached through `set_admin/3` (and, in `test/support/fixtures/accounts_fixtures.ex`, applied directly to make the first admin — there is no admin actor to authorise that one). Any new privileged field follows the same shape: its own narrow changeset, never in the public `cast`.

7. **A magic link is the recovery path, and it discards any password it finds — unconditionally.** `Accounts.login_user_by_magic_link/1` is **arity 1**, the generator's arity: no session argument, no caller-identity branch. When the token resolves to an unconfirmed account that already holds a password — the "Mixing magic link and password registration" case in `mix help phx.gen.auth`, which registration walks into every time — it confirms, logs the person in, and **always** discards the password via `User.confirm_and_clear_password_changeset/1`.

   There is no signed-in exception, and reintroducing one would be a security regression, not a convenience. For an *unconfirmed* account the only session that can exist is the one registration minted — i.e. one derived from the very password under suspicion — so "already signed in as that user" proves nothing about who owns the inbox. Honouring it would narrow credential pre-stuffing to session fixation rather than close it (D-017 supersedes that half of D-015). **Never reintroduce a second argument or any caller-identity branch:** [test/consensus/accounts_test.exs](test/consensus/accounts_test.exs) asserts `refute function_exported?(Accounts, :login_user_by_magic_link, 2)`.

   Whoever controls the inbox is the owner, so a pre-stuffing attacker's credential stops working the moment the real owner clicks; the owner lands in sudo mode and sets a new password from Settings. Callers must expect a `%User{hashed_password: nil}` back and say so: `ConsensusWeb.UserSessionController` flashes that the password was removed, and `ConsensusWeb.UserLive.Confirmation` warns **before** the button is pressed (the assign is `@clears_password?`, now computed from the user alone — `is_nil(confirmed_at) and not is_nil(hashed_password)`, no `@current_scope` input — so it fires for a signed-in owner too). **Never** write that a magic link is refused or that a user must "log in with their password first" — that was D-005, and D-015 superseded it.

   That controller clause is one of **four** `UserAuth.disconnect_sessions/1` call sites in `lib/` — the other three are `update_password/2` in the same controller, and the demote and delete branches of `AdminLive.Users` — and the reason for this one is that the link expires every other token for the account, so the live sockets holding them have to go. It is regression-guarded by "broadcasts a disconnect for every token the magic link expires" in [test/consensus_web/controllers/user_session_controller_test.exs](test/consensus_web/controllers/user_session_controller_test.exs), which subscribes to `"users_sessions:" <> Base.url_encode64(token)` and asserts the `%Phoenix.Socket.Broadcast{event: "disconnect"}`. Deleting that line used to leave the whole suite green.

8. **The bootstrap default password is loud on purpose.** `aheld` / `adminpass` (9 chars, under the 12-char minimum everyone else gets — seeding passes `validate_length: false`). **The waiver applies to the built-in `adminpass` and nothing else:** an operator who sets `ADMIN_PASSWORD` is held to the full 12-character rule, because waiving it for them would silently accept a one-character production admin password. The app logs a warning on every boot and `ConsensusWeb.AdminLive.Users` renders a banner while `Consensus.Seeds.default_password_in_use?/0` is true. Do not silence either. That predicate costs one bcrypt verification per admin, so it belongs on admin pages, never in a hot path.

9. **Mail delivery is best-effort and must never fail a request.** `Consensus.Accounts.UserNotifier.deliver/3` wraps `Mailer.deliver/1` in a `catch`, so both an `{:error, _}` tuple **and a process exit** become a logged `{:error, reason}` at `:error` level. An `exit` is not caught by `with`, and that is not hypothetical: `Swoosh.Adapters.Local` (config/config.exs) plus `config :swoosh, local: false` (config/prod.exs) meant every release delivery called a GenServer that does not exist. Production now pins `Swoosh.Adapters.Logger` in `config/runtime.exs`, ahead of the commented provider examples so a real provider still wins. A failed confirmation email must never lose an account that has already been created — `ConsensusWeb.UserLive.Registration` therefore does not assert `{:ok, _} = ` on it. Regression-guarded by [test/consensus/accounts/user_notifier_test.exs](test/consensus/accounts/user_notifier_test.exs), which needs two stand-in adapters (one that exits, one that returns `{:error, _}`) because `Swoosh.Adapters.Test` reproduces neither.

10. **CI must run the image it builds, not just build it.** The `docker` job in [.github/workflows/ci.yml](.github/workflows/ci.yml) builds with `load: true` (tag `consensus:ci`), then runs **two** boot steps. The first, *"Boot the release image and smoke test it"*, boots one container against a tmpfs `/data` owned by uid 65534 and asserts five things in order:

    1. `/health` answers `200 ok` (polled for up to 60s at `http://127.0.0.1:4000/health`);
    2. `/health` answers `200` again **under `Host: $PHX_HOST`**, where `$PHX_HOST` is `sed`-extracted from `fly.toml`'s `[env]` block rather than hardcoded. This is the *only* assertion that proves the `force_ssl` `paths: ["/health"]` exclusion in `config/prod.exs` — the first poll went to `Host: 127.0.0.1`, which the sibling `hosts: ["localhost", "127.0.0.1"]` exclusion already covers, so it would stay green with `paths:` deleted. Fly's checker sends the machine's own hostname, not `127.0.0.1`;
    3. a **real LiveView websocket handshake returns 101** against `/live/websocket?vsn=2.0.0`, sent with `Host`/`Origin` set to `$PHX_HOST` and `x-forwarded-proto: https`. `check_origin` defaults to `true` in prod and validates `Origin` against the endpoint's `:url` host, which comes from `PHX_HOST`; a mismatch 403s every socket while `GET /` and `/health` both keep answering 200. Every user-facing page here is a LiveView, so that is a total, invisible outage. The `|| true` on that curl is load-bearing — a *successful* upgrade holds the connection open and curl exits 28 once `--max-time` elapses, having already written the status;
    4. `Consensus.Accounts.count_admins() == 1` over `/app/bin/consensus rpc`;
    5. the schema is broken over `rpc` (`ALTER TABLE users RENAME TO users_gone`) and `/health` must then answer 503.

    The second step, *"Boot twice on one volume, migrating a populated database"*, is the upgrade rehearsal. It boots on a **real named Docker volume**, renames the seeded admin, stops the container, rolls the newest migration down via `bin/consensus eval`, then boots a second container on the same volume and asserts `/health` 200, a `== Migrated` line in the logs, still exactly one admin, and that the admin still carries its *new* name. Everything else in the repo starts from an empty database, so without this nothing ever migrated a populated one — which is what every deploy after the first does. It also re-proves `Consensus.Seeds`' zero-admins gate: a rename must not look like a first boot.

    Together these are the **only** thing in the repo that exercises the boot-time `{Ecto.Migrator, ...}` child, `Consensus.Seeds`, `Consensus.BootCheck.run!/0` and the `config_env() == :prod` half of `config/runtime.exs` — `mix test` never starts a release, and `elixirc_paths(:test)` does not even compile `*_test.exs` under `mix compile`, so a whole class of break is invisible to the compile gate too. Do not reduce this to a plain `docker build`; a build-only job is what let the `/health` regression deploy green. The tmpfs `uid=65534,gid=0` matches how Fly presents an *empty* volume to a release running as `nobody`; do not "fix" a failure there by running the container as root — a root-owned `/data` is precisely what the preflight in invariant 3 exists to reject.

    **What the docker job cannot catch:** it feeds the container the same `PHX_HOST` it then asserts against, so `fly.toml`'s `app` and `PHX_HOST` drifting apart is invisible to it. That is [test/consensus/deploy_config_test.exs](test/consensus/deploy_config_test.exs)'s job (D-023), and it fails in seconds on a pull request instead of after a full image build. It also cannot catch a migration that has never run anywhere — the pending migration in step two already succeeded on the first boot.

    `fly-deploy.yml` calls `ci.yml` via `workflow_call`, so the deploy gate includes both boot steps automatically: a release that fails to boot can no longer reach Fly. They cost the `docker` job roughly a minute.

11. **The home-page message is whitespace-significant in two places, and `mix format` cannot police either.** `/` renders the admin message inside a `whitespace-pre-wrap` paragraph, so the message string's line structure *is* its rendered layout. Consequently: in the HEEx template the `<p id="home-message">` element carries `phx-no-format`, and its opening `>` sits immediately before `{@home_page.message}` with the closing `</p>` immediately after — no newline or indentation on either side, since with `pre-wrap` that whitespace is rendered text. (Its *attributes* may sit on their own lines; they do.) That element also carries **`aria-live="polite"`**: it is the one thing in the app that changes under a visitor who never navigates — an admin's save arrives over PubSub — so without a live region a screen-reader user is simply never told. `polite`, not `assertive`, because an assertive region interrupts whatever the reader is currently speaking, which is wrong on a page whose entire content is prose; it also matches the flash group, which is already polite. And `Consensus.Content`'s default message is `@default_message_lines` — a list of strings joined with `"\n"`, one element per rendered line — rather than a heredoc. Neither may be reflowed to fit a source margin. `mix format` never reflows string contents, so a wrapped heredoc leaks straight into the page and the formatter reports nothing; this defect shipped twice. The guards are behavioural: `"default_message/0"` in [test/consensus/content_test.exs](test/consensus/content_test.exs) (no leading or trailing whitespace on any line; no non-empty line ending anywhere but `.`, `!` or `?` — **a colon is no longer accepted, and that tightening was the point**: the default message holds exactly one colon, mid-line, at the single most tempting place to wrap the source, and splitting there left one fragment ending in `:` and one ending in `.`, both of which the old guard waved through) and an assertion in [test/consensus_web/live/home_live_test.exs](test/consensus_web/live/home_live_test.exs) that extracts the rendered `<p id="home-message">` body and compares it byte for byte against the HTML-escaped stored message — so putting a newline after that `>` fails a test rather than passing a cosmetic check. See D-020.

**Known gap, not an invariant:** production has a mail *adapter* but no mail *provider*. `Swoosh.Adapters.Logger` logs the recipient — deliberately not the body, so no working magic link reaches `fly logs` — and returns `{:ok, _}`. Nothing is actually delivered. Magic-link login and the confirm-your-email-change flow therefore reach nobody in production; registration takes a password and signs the new account in immediately, so nobody is blocked. Don't document magic-link login as a working production path until a provider lands in `config/runtime.exs` — it is a one-line change. Until then, `Accounts.delete_user/2` from `/admin/users` is the recovery lever this deployment actually has.

## Product invariants

These come from the PRD. They describe where the app is going, and should not be traded away for implementation convenience when the voting features get built.

1. **Voter friction is zero.** A guest voting via a shared link never sees a signup, a password, an email field, or an app-store redirect. Name entry (or anonymous) is the maximum ask. Note this is *orthogonal* to the account system that exists today — accounts are for organizers and admins, never for voters.
2. **The engine is activity-agnostic.** Nothing in the voting, tally, or session-lifecycle code may reference `restaurant`. Dining is one activity module among several (movie, travel, lodging, custom).
3. **Every session has a hard deadline.** Voting locks automatically; a winner is declared without organizer intervention.
4. **Results are real-time.** Participants see vote state update without a manual refresh. (The mechanism already in the repo: `Phoenix.PubSub` + LiveView, as `Consensus.Content` / `ConsensusWeb.HomeLive` do it today.)
5. **The session ends in an action, not a summary.** A winner renders a booking/ticketing CTA plus a runner-up failsafe and a paste-back-to-chat summary string.
6. **Anonymous voting is a first-class mode**, not a toggle bolted on later — it's the core relief for the indecisive-voter persona.

Primary success metric: **Time to Consensus under 5 minutes.** Guest drop-off on the link interface under 5%.

### Scope discipline

MVP is the dining module only. Explicitly Post-MVP, do not build early: ranked-choice voting (Borda / IRV), two-phase sequential funnels (movie → showtime), TMDB / Fandango / Gracenote integrations, travel & lodging modules, saved friend groups and venue blacklists. Post-MVP features may inform the *shape* of MVP data models so the refactor isn't painful, but no Post-MVP code paths.

## Working agreements

- **Non-trivial features get a plan first** in `docs/plans/<feature>.md`. See [docs/plans/README.md](docs/plans/README.md) for what a plan must cover; reference the relevant `D-00N` entries so a plan can't quietly contradict a settled decision.
- **Any settled technical choice gets appended to [docs/decisions.md](docs/decisions.md)** with the date and the reasoning — including choices made mid-conversation. The template is at the bottom of that file. Delete the corresponding entry from `open-questions.md` when you do.
- **A new `D-00N` that changes something an earlier entry states must edit that earlier entry in the same change.** Appending is not enough. `decisions.md` is declared the top technical authority above, so a reader resolving a question stops at the first entry that answers it — an entry left saying `settled` while the code has moved on is not stale documentation, it is a wrong answer delivered with authority. Concretely: flip the old `Status` to `superseded by D-00N`, mark the specific stale `Decision`/`Consequences` lines as history rather than instruction, and fix any function name, arity, file path, config key or quoted code block the change invalidated. Grep the whole file for the old name before you finish — D-005, D-006 and D-012 each went wrong exactly this way.
- **When a change invalidates a fact, grep for that fact across every doc before you finish.** Concretely: for every route path, function name, *arity*, module name, config key, file name, log message and test count the change touches, `grep` [README.md](README.md), [CLAUDE.md](CLAUDE.md) and [TODO.md](TODO.md) (plus `docs/decisions.md`, which the rule above already covers) and fix or delete every hit. This is not hygiene, it is the failure mode this repo actually has: D-016 moved the Fly health check from `GET /` to `GET /health` and propagated to `fly.toml`, `CLAUDE.md`, `TODO.md` and `decisions.md` — README was the one file nobody grepped, and it sat telling operators to configure a check that provably 301s and can never go green. A doc that is confidently wrong is worse than one that is silent.
- **Run `mix precommit` before committing.** The alias is real: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`, and `mix.exs` sets `preferred_envs: [precommit: :test]` so it runs in `MIX_ENV=test`. It is **necessary but not sufficient** — CI also runs `mix deps.get --check-locked`, `mix deps.unlock --check-unused`, `mix format --check-formatted` (an assertion, where `precommit` rewrites files), and a `docker` job that **builds the release image and then boots it twice** (invariant 10), which is the only place the boot path runs at all. The full local reproduction, command for command, is the "Reproducing CI locally, completely" section of [.claude/skills/elixir/SKILL.md](.claude/skills/elixir/SKILL.md) — do not paraphrase it as "and a `docker build`".
- **Secrets never land in the repo.** `.gitignore` covers `.env` and `.env.*` (with `!.env.example`). In production use `fly secrets set` — `SECRET_KEY_BASE` is required and the app raises at boot without it. `ADMIN_PASSWORD` should be set *before* the first deploy.
- **External API calls** (Places/Yelp, later TMDB) must go through a caching layer from the first commit that touches them — per-query cost is the roadmap's top financial risk.
- **Follow [AGENTS.md](AGENTS.md)** for code style, HEEx, forms, streams, and test conventions. Don't restate its rules here; don't restate repo facts there.

## Commands

`mix` lives in `/opt/homebrew/bin`. Prefix with `export PATH="/opt/homebrew/bin:$PATH"` if it isn't on your `PATH`.

| Command | What it does |
|---|---|
| `mix setup` | `deps.get`, `ecto.setup`, `assets.setup`, `assets.build`. First run in a fresh checkout. |
| `mix phx.server` | Dev server on <http://localhost:4000>. Does **not** migrate or seed — `RELEASE_NAME` is unset outside a release. |
| `iex -S mix phx.server` | Same, with a shell. |
| `mix ecto.setup` | `ecto.create`, `ecto.migrate`, `run priv/repo/seeds.exs`. |
| `mix ecto.reset` | `ecto.drop` then `ecto.setup`. Destroys the dev database. |
| `mix ecto.gen.migration name_with_underscores` | Always generate migrations this way (correct timestamp + conventions). |
| `mix test` | Full suite. Verified 2026-08-08: **323 tests, 0 failures**, ~1.7s warm (0.4s async, 1.3s sync); budget ~8s on the first run after a cold `_build`. The alias prepends `ecto.create --quiet` and `ecto.migrate --quiet`. Set `MIX_TEST_PARTITION=<n>` to get your own `consensus_test<n>.db` if another agent may be running the suite — `mix precommit` honours it too (the alias runs in one OS process and `config/test.exs` reads the variable with `System.get_env/1`), so a partitioned `precommit` never touches `consensus_test.db`. |
| `mix test test/path/to/file.exs` / `mix test --failed` | Narrow a failure. |
| `mix format --check-formatted` | Verified clean. What CI runs. |
| `mix compile --warnings-as-errors` | Verified clean. What CI runs. |
| `mix precommit` | The pre-commit gate. See working agreements above. |
| `mix phx.routes` | Route table. Under `MIX_ENV=dev` it includes `/dev/mailbox`, which does not exist in prod. |
| `docker build -t consensus:ci .` | Verified to succeed. Same image and same tag CI builds. Run it with `-v` mounting something at `/data` plus `DATABASE_PATH=/data/consensus.db` — since `VOLUME /data` was removed, a `docker run` with no `-v` writes into the container and loses the data on `docker rm`. |
| the boot smoke test, locally | Mirrors CI's `docker` job (invariant 10). Take the whole recipe — build tag, both boot steps, all five assertions — from "Reproducing CI locally, completely" in [.claude/skills/elixir/SKILL.md](.claude/skills/elixir/SKILL.md) rather than from memory. Two things that recipe gets right and an ad-hoc `docker run` does not: `PHX_HOST` must be read out of `fly.toml` (`sed -n "s/^[[:space:]]*PHX_HOST[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" fly.toml`), **never `localhost`** — `localhost` and `127.0.0.1` are on the `hosts:` exclusion in `config/prod.exs`, so `force_ssl` is bypassed wholesale and a 200 there proves nothing about the `paths: ["/health"]` exclusion or about `check_origin`; and the container needs `--tmpfs /data:rw,mode=0750,uid=65534,gid=0`. Clean up with `docker rm -f consensus-smoke consensus-upgrade-1 consensus-upgrade-2` and `docker volume rm consensus-upgrade`. |
| `fly deploy` / push to `main` | Deploy. CI gates it; `flyctl deploy --remote-only --ha=false`. Load the `fly-io` skill first. |

`flyctl` (v0.4.79) is installed locally, but this machine is **not logged in** — `fly <cmd> --help` and `fly version` work; anything that touches an app does not. Note `fly open` is deprecated in favour of `fly apps open`.

**Local admin login:** `aheld` / `adminpass` at `/users/log-in` (the login field accepts username *or* email), then `/admin/users`. In dev, magic-link and confirmation emails land in Swoosh's preview at `/dev/mailbox`.
