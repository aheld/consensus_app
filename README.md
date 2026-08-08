# Consensus

A Phoenix 1.8 / LiveView application: SQLite-backed, deployable to a single Fly.io machine,
with username-or-email authentication, an admin area, and a public home page whose content an
administrator edits at runtime — every open browser sees the change without a refresh.

> **Read this before you clone.** The application code is **not committed yet.** `git ls-files`
> currently returns ten files — `.gitignore`, `.claude/settings.json`, `CLAUDE.md`, `README.md`
> and the six files under `docs/`. Everything this README describes below (`mix.exs`, `lib/`,
> `config/`, `test/`, `priv/`, `assets/`, `Dockerfile`, `fly.toml`, `.github/`, `rel/`,
> `AGENTS.md`, `TODO.md`) exists in the working tree but is **untracked**, so a fresh
> `git clone` produces a checkout with no application in it — `mix setup` there fails with
> `** (Mix) The task "setup" could not be found`.
>
> The first commit is the repository owner's to make, and [TODO.md](TODO.md) **§1, "Push this
> repository to GitHub"**, is the checklist that does it (`git add -A`, review what
> `.gitignore` catches, commit, push). Everything below assumes you are working **in this
> directory**, not in a clone of it. Run `git ls-files` if you are unsure which you have.

**Status.** What is in this working tree today is a production-ready *foundation*: accounts,
sessions, roles, an admin area, first-boot seeding, a Docker release image, and a CI/CD
pipeline. The product it is a foundation *for* — a group activity-voting PWA where an organizer
shares a link and 4–7 friends vote with no downloads and no accounts — is specified in
[docs/PRD.md](docs/PRD.md) and is not built yet. Technical decisions are logged in
[docs/decisions.md](docs/decisions.md); open ones in
[docs/open-questions.md](docs/open-questions.md).

---

## ⚠️ Security: change the bootstrap admin password

A fresh database is seeded with an administrator account:

| | |
|---|---|
| username | `aheld` |
| email | `aheld@example.com` |
| password | `adminpass` |

**`adminpass` is nine characters — below the twelve-character minimum this app enforces on
every other password** ([`Consensus.Accounts.User.min_password_length/0`](lib/consensus/accounts/user.ex)).
Seeding passes `validate_length: false`, which does not skip the length check but relaxes it: the
minimum drops from twelve characters to one, and the 72-byte bcrypt ceiling still applies. That is
what lets the documented default work out of the box. Anyone who can reach a deployment still
running it can sign in as an administrator.

The waiver is scoped to that one string. [`Consensus.Seeds`](lib/consensus/seeds.ex) passes
`validate_length: false` **only** when the password it is about to use is literally `adminpass`;
an `ADMIN_PASSWORD` you set is held to the full twelve-character rule, so a one-character
production admin password is rejected at seed time rather than accepted silently.

The app does not let you forget: [`Consensus.Seeds`](lib/consensus/seeds.ex) logs a warning on
**every boot** while the default is in place, and `/admin/users` renders a warning banner naming
every account `Consensus.Seeds.admins_with_default_password/0` returns. Both check the
*password*, not the username — renaming the bootstrap account does not silence either one.

Two ways to fix it. Pick one.

**A. Already running — change it in the app.**

1. Log in at `/users/log-in` as `aheld` / `adminpass`.
2. Go to `/users/settings` (Account Settings). This page requires *sudo mode* — an
   authentication within the last 10 minutes — which you have just satisfied by logging in.
3. Set a new password of at least 12 characters and save.

Saving expires every other session token for that account, and the boot warning and the admin
banner stop appearing.

**B. Before the first deploy — never seed the default at all.**

`Consensus.Seeds` reads `ADMIN_USERNAME`, `ADMIN_EMAIL` and `ADMIN_PASSWORD` — but only on the
boot that actually creates the bootstrap account, and it creates one only while the database has
**no administrator at all** (`Accounts.count_admins() == 0`). Set all three *before* the first
boot. Once any admin exists, `Consensus.Seeds.run!/0` returns `admin: nil` and touches nothing, so
setting `ADMIN_PASSWORD` afterwards does nothing.

```sh
# Fly.io — before `fly deploy` creates the machine for the first time:
fly secrets set ADMIN_PASSWORD='a-long-password-you-generated'
fly secrets set ADMIN_USERNAME='you' ADMIN_EMAIL='you@example.com'   # optional

# Local:
ADMIN_PASSWORD='a-long-password-you-generated' mix ecto.setup
```

Docker, against the release image built from [`Dockerfile`](Dockerfile). `SECRET_KEY_BASE` **and**
`DATABASE_PATH` are both mandatory — [`config/runtime.exs`](config/runtime.exs) raises at boot if
either is missing. Build the image first; CI tags it `consensus:ci`, so use that name and there is
one fewer thing to translate:

```sh
docker build -t consensus:ci .

docker run --rm -p 4000:4000 \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e DATABASE_PATH=/data/consensus.db \
  -e PHX_HOST=localhost \
  -e ADMIN_PASSWORD='a-long-password-you-generated' \
  -v consensus_data:/data \
  consensus:ci
```

`PHX_HOST=localhost` is right **for this** — poking at the app in a browser at
`http://localhost:4000`. `force_ssl` in [`config/prod.exs`](config/prod.exs) excludes the hosts
`localhost` and `127.0.0.1` outright, so any other value redirects you to HTTPS the container does
not serve, and `check_origin` would reject the LiveView socket.

**Do not use `localhost` when the point is to reproduce CI.** That same `hosts:` exclusion bypasses
`force_ssl` wholesale, so a `200` from `curl localhost:4000/health` proves nothing about the
separate `paths: ["/health"]` exclusion that Fly's checker actually depends on — and an `Origin` of
`localhost` proves nothing about `check_origin` against the deployed hostname. CI therefore reads
`PHX_HOST` out of `fly.toml` and asserts against *that*. The full local reproduction is in
[.claude/skills/elixir/SKILL.md](.claude/skills/elixir/SKILL.md), "Reproducing CI locally,
completely"; see also *Testing* below.

Back to the volume: `/data` is created and owned by the release image's `nobody` user, and the named volume keeps the
database across `docker run` invocations. **The `-v` is not optional if you want the data to
survive**: the Dockerfile deliberately declares no `VOLUME /data`, so a run without it writes into
the container filesystem and loses the database when the container is removed — honest behaviour,
rather than an anonymous volume that looks durable and is not. The container listens on `PORT`,
which defaults to `4000`; set it to `8080` to match `fly.toml` if you want to mirror production
exactly.

---

## Quick start

**From this directory, not from a clone** — see the note at the top of this file: the code is
untracked, so cloning gets you the docs and nothing else. [TODO.md](TODO.md) §1 is how it becomes
a real repository.

**Prerequisites:** Elixir 1.20.3 on Erlang/OTP 29.0.5 — the versions pinned by
[`Dockerfile`](Dockerfile) (`ARG ELIXIR_VERSION` / `ARG OTP_VERSION`) and by the CI matrix in
[.github/workflows/ci.yml](.github/workflows/ci.yml). Check yours:

```sh
elixir --version
# Erlang/OTP 29 [erts-17.0.5] ...
# Elixir 1.20.3 (compiled with Erlang/OTP 29)
```

(`mix.exs` declares the looser `elixir: "~> 1.17"`; the pinned pair above is what is actually
built and tested.) Docker is needed only to build the release image.

```sh
mix setup        # deps.get, ecto.create + migrate + seed, assets.setup, assets.build
mix phx.server   # or: iex -S mix phx.server
```

Then open <http://localhost:4000>. `mix setup` prints the seeded credentials; they are
`aheld` / `adminpass` unless you overrode them — **read the security section above**.

The dev database is a file: `consensus_dev.db` in the project root (`consensus_test.db` for
tests). `mix ecto.reset` drops and rebuilds it.

---

## Feature tour

| Route | What it is |
|---|---|
| `/` | Public home page ([`ConsensusWeb.HomeLive`](lib/consensus_web/live/home_live.ex)). Renders the admin-editable message. Subscribes to `Consensus.Content`, so an admin's edit appears here live, in every open browser. |
| `/users/register` | Sign-up: **username + email + password**. Creates the account and signs it in immediately. |
| `/users/log-in` | Two forms on one page: password log-in (the identifier field accepts **either** the username or the email), and magic-link log-in by email. |
| `/users/log-in/:token` | Magic link landing page. Always usable. When an unconfirmed account already holds a password, the page warns **before** the button is pressed that confirming here will remove that password, then confirms and signs you in (see the recovery section below). |
| `/users/settings` | Change username, email, or password. Gated by sudo mode (`:require_sudo_mode`) on top of authentication. Email changes go through a confirmation link; username changes do not — a username is an in-app identifier, not proof of controlling an inbox. |
| `/users/log-out` | `DELETE`. Deletes the session token and broadcasts a disconnect to that session's LiveViews. |
| `/admin`, `/admin/users` | Admin → Users ([`AdminLive.Users`](lib/consensus_web/live/admin_live/users.ex)). Lists every account; **Promote**, **Demote** and **Delete**. Refuses to demote the last admin (`{:error, :last_admin}`); both demotion and deletion disconnect that user's live sessions. **Delete** renders only for a non-admin who is not you — demote an administrator before deleting them — and is the account-recovery lever on a deployment with no mail provider. All three actions need **sudo mode** (a log-in within the last 20 minutes): out of it, the page shows a `#sudo-notice` banner and greys the buttons, and `Consensus.Accounts` refuses regardless of what the client sends. Renders the default-password banner. |
| `/admin/home-page` | Admin → Home page. Edits the `/` message (plain text, 2000 graphemes and 8000 bytes max). The textarea deliberately has **no `maxlength`** — a browser counts UTF-16 code units and truncates a paste silently; a live grapheme counter under the field warns instead, and the changeset enforces. Saving broadcasts over PubSub. |
| `/admin/dashboard` | Phoenix LiveDashboard. Mounted in **every** environment, admin-only — not left on `:dev_routes`. |
| `/dev/mailbox` | Swoosh mailbox preview. Development only, gated on `Application.compile_env(:consensus, :dev_routes)`. |
| `/health` | Readiness probe for Fly's health checker ([`HealthController`](lib/consensus_web/controllers/health_controller.ex)). Outside the `:browser` pipeline — no session, CSRF or layout — and excluded from `force_ssl`. `200 ok` only when no migration is pending *and* the `users` table is readable; otherwise `503`. See *Deployment*. |

`mix phx.routes` prints the authoritative list.

---

## Architecture

**Contexts** (`lib/consensus/`):

- [`Consensus.Accounts`](lib/consensus/accounts.ex) — users, session tokens, magic links,
  registration, and the admin role. Notable functions: `get_user_by_login/1` (dispatches on the
  presence of `@` to email or username lookup), `get_user_by_login_and_password/2`,
  `create_user/2` (the seeding path — accepts `:is_admin` and `:confirmed_at`, which
  `register_user/1` deliberately does not), and `get_user/1`, which returns `nil` for anything
  outside a valid 64-bit row id rather than handing exqlite an integer it raises on.

  Both of the destructive ones take the **actor's** scope as their first argument, re-read
  authorization from the database inside their own transaction (because a mounted LiveView holds
  whatever scope it mounted with), require the actor to be in **sudo mode** — a re-authentication
  within the last 20 minutes, or `{:error, :sudo_required}` — and return
  `{:ok, {user, tokens_to_disconnect}}` on success:

  - `set_admin/3` — `set_admin(actor_scope, user, is_admin)`. Re-reads the *actor's* admin role
    and the target user inside one `Repo.transact/1`, refuses to revoke the last admin
    (`{:error, :last_admin}`). A demotion
    yields that user's session tokens, which `ConsensusWeb.UserAuth.disconnect_sessions/1` uses
    to force a remount — so an admin demoted while `/admin/users` was open in another tab cannot
    keep acting from it.
  - `delete_user/2` — admin-only. Refuses to delete an administrator (demote first,
    `{:error, :is_admin}`) and refuses self-deletion (`{:error, :self}`). Session tokens go with
    the row by `ON DELETE CASCADE` — collected *before* the delete, so they can still be
    disconnected — and `home_page.updated_by_id` is nulled by `ON DELETE SET NULL`.

  Both also write an audit line: `[audit] grant_admin|revoke_admin|delete_user actor_id=… actor=…
  target_id=… target=…` at `:info` on success, and `[audit] … REFUSED <reason> …` at `:warning` on
  every refusal. Ids lead because usernames are mutable, and nothing password-derived is logged.
  With one machine, no external audit sink and no undo, that line is the only record of who
  promoted or deleted whom — and a run of `REFUSED :unauthorized` is what someone acting from a
  revoked session looks like. See [docs/decisions.md](docs/decisions.md) D-021.
- [`Consensus.Content`](lib/consensus/content.ex) — runtime-editable site content, today just
  the home page message. Reads are open; `update_home_page/2` pattern-matches
  `%Scope{user: %User{is_admin: true}}` in the function head, so a non-admin call raises
  `FunctionClauseError` rather than taking a runtime branch — and then re-reads the actor's role
  from the database, returning `{:error, :unauthorized}` for an admin who was demoted while the
  editor tab stayed open. The row is a singleton (`id = 1`,
  enforced by a CHECK constraint in
  [the migration](priv/repo/migrations/20260808040000_create_home_page.exs)).

**Web layer** (`lib/consensus_web/`): two controllers of its own, plus the generated error views.
[`UserSessionController`](lib/consensus_web/controllers/user_session_controller.ex) exists because
LiveViews cannot write the session cookie, so anything that establishes a session hands off to it
via `phx-trigger-action`;
[`HealthController`](lib/consensus_web/controllers/health_controller.ex) answers `/health` for
Fly's checker (see *Deployment*) and is a controller precisely because it must not open a
websocket, a session or a layout. `error_html.ex` and `error_json.ex` are generator output.
Everything else is a LiveView. Phoenix 1.8 scopes are used
throughout: `@current_scope` holds a [`Consensus.Accounts.Scope`](lib/consensus/accounts/scope.ex),
never a bare `current_user`.

**Authorization** lives in [`ConsensusWeb.UserAuth`](lib/consensus_web/user_auth.ex) and is
applied twice to every admin route, because a plug pipeline does not run for a LiveView
websocket connection:

- the `:require_authenticated_user` and `:require_admin_user` **plugs** reject the initial HTTP
  request, and
- the `:require_admin` **`on_mount` hook** on the `live_session` rejects the socket mount.

Non-admins who are already signed in are redirected to `/` (not to the log-in form, which would
be a dead end); anonymous visitors are sent to `/users/log-in` with a stored return path. See
[`router.ex`](lib/consensus_web/router.ex).

**Live updates** use `Phoenix.PubSub` on the topic `content:home_page`. `HomeLive.mount/3` calls
`Content.subscribe_home_page/0` when `connected?(socket)`; a successful `update_home_page/2`
broadcasts `{:home_page_updated, home_page}`; `HomeLive.handle_info/2` re-assigns. No polling,
no manual refresh.

**Boot order** ([`Consensus.Application`](lib/consensus/application.ex)). Before any child starts,
`start/2` calls [`Consensus.BootCheck.run!/0`](lib/consensus/boot_check.ex), which preflights the
SQLite file three ways:

- it creates the directory `DATABASE_PATH` points into if absent, and writes and removes a probe
  file there;
- it opens every existing member of the **WAL set** for append — `DATABASE_PATH` plus `<path>-wal`
  and `<path>-shm`. A directory-only probe misses a file inside a writable directory that belongs
  to root, and a `DATABASE_PATH`-only probe misses a root-owned sidecar beside a database that
  still looks perfectly healthy. Production runs `journal_mode: :wal`, so SQLite must write all
  three and cannot start without them. Each member is filtered through `File.exists?/1`, so a
  first boot (none present) and a cleanly checkpointed database (sidecars gone) both pass;
- it compares that directory's device id against `/`. If they match, no volume is mounted there:
  on Fly (`FLY_APP_NAME` set) that **raises and fails the deploy**, and elsewhere it only logs a
  warning, so a quick `docker run` with no `-v` still works.

The first two raise `Cannot write the SQLite database (…)` and lead with a
`refused       : <path>` line naming the file that actually said no — then `DATABASE_PATH`, the
directory, every member of the WAL set with its uid/gid/mode, the release user (`nobody`, uid
65534) and the one-line remedy (`fly ssh console -u root -C "chown -R 65534:0 /data"`). Without it,
a root-owned volume produces eleven `database_open_failed` lines and a
`DBConnection.ConnectionError` about connection pools, which sends you reading about pool sizes.
The third raises or logs `… is not a mount point — it is
part of the container filesystem.` — failing the deploy is right there, because the database is
empty by definition at that moment and the alternative is discovering it after the *next* deploy
destroys real data.

From `Consensus.Application` the check is skipped outside a release, on the same `RELEASE_NAME`
test as migrations. **All three `Consensus.Release` entry points — `migrate/0`, `seed/0` and
`rollback/2` — run it unconditionally:** they execute in a fresh node via `bin/consensus eval`,
never touch `Application.start/2`, and are exactly what you reach for when something is already
wrong. `rollback/2` used to be exempt; it is the command most likely to be typed at a machine that
is already broken, so it no longer is. See [docs/decisions.md](docs/decisions.md) D-022.

```
ConsensusWeb.Telemetry
Consensus.Repo
{Ecto.Migrator, repos: ..., skip: skip_migrations?()}
{Consensus.Seeds,             skip: skip_seeds?()}   # must stay directly after Ecto.Migrator
{DNSCluster, ...}
{Phoenix.PubSub, name: Consensus.PubSub}
ConsensusWeb.Endpoint
```

Both `Ecto.Migrator` and `Consensus.Seeds` run synchronously during supervisor init and return
`:ignore`, so by the time the endpoint accepts traffic the schema is current and the deployment
has an administrator. `skip_migrations?/0` is `System.get_env("RELEASE_NAME") == nil` — which is
why `mix phx.server` does *not* auto-migrate but a release does. `skip_seeds?/0` follows it unless
`:seed_on_boot` is configured; `config/test.exs` pins that to `false` so seeded data never leaks
into an assertion.

The same idempotent `Consensus.Seeds.run!/0` is reachable from three places: the supervision
tree, [`priv/repo/seeds.exs`](priv/repo/seeds.exs) (via `mix ecto.setup`), and
`Consensus.Release.seed/0` (by hand, e.g. over `fly ssh console`). It ensures the home page row,
then creates a bootstrap admin only if `Accounts.count_admins()` is `0` — keyed on the *role*, not
on the username, so renaming or re-emailing the account cannot make the next boot look like a first
boot and recreate `aheld` with the documented default password. Where an admin already exists it
returns `{:ok, %{admin: nil, home_page: home_page}}`.

---

## How authentication differs from stock `mix phx.gen.auth`

The generator was run as `mix phx.gen.auth Accounts User users` (Phoenix 1.8 scopes, magic link,
password, sudo mode). Five deliberate divergences:

**1. Users have a unique, case-insensitive `username`.** Added to the initial migration rather
than a follow-up one, because the schema has never been deployed and because SQLite cannot add a
`NOT NULL` + `UNIQUE` column to a populated table without a table rewrite. The column is declared
`COLLATE NOCASE`, so `Accounts.get_user_by_username/1` is case-insensitive for free. Usernames
are 3–30 characters of `[a-zA-Z0-9_-]`.

**2. Users have an `is_admin` boolean**, changed only through
[`User.admin_changeset/2`](lib/consensus/accounts/user.ex) — which casts *nothing* but
`:is_admin`, so an admin-only endpoint can never be used to smuggle through an email, username,
or password change.

**3. Registration takes a password and signs the user in immediately.** Stock 1.8 registration is
magic-link-only: you register, then click a link in an email to get a session. That makes the app
unusable on a fresh deploy with no mail provider configured — and this one ships without one (see
the caveat below). So `/users/register` takes username + email + password, and hands the populated
form to `UserSessionController` via `phx-trigger-action` to obtain a signed session cookie.

**4. Log-in accepts a username or an email.** The form posts `user[login]`;
`UserSessionController.create/2` also accepts `user[email]` because the registration and
password-change forms post that. Failures return a single message — *"Invalid email/username or
password"* — that does not disclose whether the identifier exists.

**5. A magic link is the password-recovery path, and an admin can delete an account.** Stock
registration sets no password, so stock never meets an unconfirmed account that holds one; this
app's does, on every sign-up. `login_user_by_magic_link/1` therefore gained a clause for that
case — note the arity is the generator's, unchanged — and `/admin/users` gained a **Delete**
action for the deployments where no email is ever delivered. Both are below.

### Credential pre-stuffing, and how a forgotten password is recovered

Because registration sets a password, a case that stock `phx.gen.auth` treats as unreachable
becomes reachable: **an unconfirmed account that already has a password.** The attack it enables
is pre-stuffing — register someone else's email address with a password of your choosing, wait
for the real owner to confirm the address by magic link, and your password is now a working
credential on a confirmed account.

The answer is not to refuse the link. It is to **throw the password away**, which is the first
clause of [`Consensus.Accounts.login_user_by_magic_link/1`](lib/consensus/accounts.ex):

```elixir
{%User{confirmed_at: nil, hashed_password: hash} = user, _token}
when not is_nil(hash) ->
  user
  |> User.confirm_and_clear_password_changeset()
  |> update_user_and_delete_all_tokens()
```

No condition, no session argument: **every** confirmation of an unconfirmed password-holding
account destroys that password. `User.confirm_and_clear_password_changeset/1` nulls
`hashed_password`, and every existing token for the account is deleted.

There used to be an `if` here that kept the password when the confirming session was already
authenticated as that user. It was removed because it did not close the attack, it renamed it: for
an *unconfirmed* account the only session that can exist is the one registration minted, which is
derived from the very password under suspicion — so "already signed in as that user" proves
nothing about who reads the inbox, and the carve-out reduced credential pre-stuffing to session
fixation. Do not put it back; `test/consensus/accounts_test.exs` asserts the arity-2 function does
not exist. See [docs/decisions.md](docs/decisions.md) D-017.

`UserSessionController` flashes *"the password that was set on this account has been removed —
choose a new one under Settings"*, and
[`UserLive.Confirmation`](lib/consensus_web/live/user_live/confirmation.ex) warns about it
**before** the button is pressed (the assign is `@clears_password?`, computed from the user alone,
so it warns the owner too). Landing that way puts you in sudo mode, so `/users/settings` is
immediately reachable to set a new password.

This defeats pre-stuffing more completely than refusing did. Whoever can read the inbox is the
owner; a password set before the address was ever confirmed proves nothing. The attacker does not
merely fail to gain a confirmed account — their credential stops working the moment the owner
clicks the link. The cost is the honest one every magic-link-as-reset system pays: a user who
registers, logs out without confirming, and then clicks their own link loses the password they
chose. The UI says so up front.

**So a forgotten password is recoverable, two ways:**

- **Where a mail provider is configured** — request a magic link from `/users/log-in`, click it,
  and set a new password under Settings. This is the ordinary path, and it is why the clause above
  discards rather than refuses.
- **Where one is not** — and this app ships without one (see the caveat below), so no link is ever
  delivered — an administrator deletes the account from `/admin/users`, which frees the email
  address and the username for a fresh registration. `Accounts.delete_user/2` refuses to delete an
  administrator (demote them first) and refuses self-deletion, so the admin area cannot be used to
  lock itself out. That is the whole reason the button exists; see
  [docs/decisions.md](docs/decisions.md) D-015.

### Caveat: production has a mail adapter, but no mail *provider*

[`config/config.exs`](config/config.exs) sets `Consensus.Mailer` to `Swoosh.Adapters.Local`, and
[`config/prod.exs`](config/prod.exs) sets `config :swoosh, local: false` — which stops Swoosh from
starting the storage process that adapter calls. In a release the two together made **every
delivery exit**, taking the calling process with it, which would have crashed sign-up. So
[`config/runtime.exs`](config/runtime.exs) pins a production adapter that works:

```elixir
config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Logger, level: :info
```

It sits ahead of the commented Mailgun example in the same file, so configuring a real provider
still wins. Delivery now always succeeds and logs the recipient — not the body, so no magic-link
token reaches the logs. Belt and braces:
[`Consensus.Accounts.UserNotifier.deliver/3`](lib/consensus/accounts/user_notifier.ex) wraps the
send in a `catch`, turning both an `{:error, _}` tuple and a process **exit** into a logged
`{:error, reason}`, so no mailer failure can ever escape into a web request. See
[docs/decisions.md](docs/decisions.md) D-014.

What that does *not* buy you is delivery. Nothing reaches an inbox in production, so magic-link
log-in and the confirm-your-email-change flow go nowhere until you configure a provider in the
"Configuring the mailer" section of `config/runtime.exs`. Password log-in — the path registration
puts everyone on — works regardless.

---

## Configuration

Every environment variable the application actually reads:

| Variable | Read at | Default | Required? |
|---|---|---|---|
| `RELEASE_NAME` | [`lib/consensus/application.ex`](lib/consensus/application.ex) (`skip_migrations?/0`) | — | Set by the release boot scripts. When absent, migrations, seeding **and** the `Consensus.BootCheck` preflight are all skipped at boot. `Consensus.Release.migrate/0`, `seed/0` and `rollback/2` preflight regardless. |
| `FLY_APP_NAME` | [`lib/consensus/boot_check.ex`](lib/consensus/boot_check.ex) | unset | No — Fly sets it. Its only use here: when `DATABASE_PATH` turns out **not** to be on a mounted volume, boot *raises* if this is set and merely logs a warning if it is not. |
| `SECRET_KEY_BASE` | [`config/runtime.exs`](config/runtime.exs), `:prod` only | none | **Yes in prod** — raises at boot. Generate with `mix phx.gen.secret`. |
| `DATABASE_PATH` | `config/runtime.exs`, `:prod` only | none | **Yes in prod** — raises at boot. Must live inside the mounted volume. |
| `PHX_HOST` | `config/runtime.exs`, `:prod` only | `"example.com"` | Effectively yes, and it must be **the hostname the browser actually uses** — `<app>.fly.dev` for a stock Fly deploy. Missing or wrong is *silent*, not fatal: it becomes the endpoint's `:url` host, `check_origin` defaults to true in prod and validates `Origin` against it, so every LiveView socket 403s while `GET /` and `/health` keep answering 200 and Fly calls the machine healthy. `test/consensus/deploy_config_test.exs` asserts `fly.toml`'s `PHX_HOST` equals `<app>.fly.dev`; CI's docker job asserts a real socket handshake returns 101. |
| `PHX_SERVER` | `config/runtime.exs` | unset | Required for a release to actually listen. `rel/overlays/bin/server` sets it. |
| `PORT` | `config/runtime.exs`, all envs | `4000` | No. Must equal `internal_port` in `fly.toml` (`8080` there). |
| `POOL_SIZE` | `config/runtime.exs`, `:prod` only | `5` | No. SQLite serialises writes; extra slots only help readers. |
| `DNS_CLUSTER_QUERY` | `config/runtime.exs`, `:prod` only | unset → `:ignore` | No. Irrelevant on a single machine. |
| `ADMIN_USERNAME` | [`lib/consensus/seeds.ex`](lib/consensus/seeds.ex) | `aheld` | No. Read only on a boot where the database holds **no administrator** (`Accounts.count_admins() == 0`) — normally the first boot. Ignored once any admin exists. |
| `ADMIN_EMAIL` | `lib/consensus/seeds.ex` | `aheld@example.com` | No. Same gate as `ADMIN_USERNAME`, and read on the same boot or not at all. |
| `ADMIN_PASSWORD` | `lib/consensus/seeds.ex` | `adminpass` | **Strongly recommended before the first boot.** See the security section. |

Also configured but not via environment: production SQLite runs `journal_mode: :wal` with
`busy_timeout: 5_000` (`config/runtime.exs`); the test database sets the same busy timeout so
concurrent async tests wait instead of raising `Exqlite.Error … database is locked`.

---

## Testing

```sh
mix test                        # 323 tests, 0 failures (~1.7s warm)
mix test test/consensus/accounts_test.exs
mix precommit                   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

Set `MIX_TEST_PARTITION=<n>` to get your own `consensus_test<n>.db` if something else may be
running the suite at the same time. `mix precommit` honours it too.

Coverage is concentrated where the divergences are: `Consensus.Accounts` (79 tests — including
username uniqueness and case-insensitivity, login-by-either-identifier, the last-admin guard,
the sudo-mode gate on both admin writes, `delete_user/2`'s refusals, and every branch of the
magic-link rule, up to an end-to-end pre-stuffing scenario and an assertion that no arity-2
`login_user_by_magic_link` exists),
`ConsensusWeb.UserAuth` (35, with `describe` blocks for `require_admin_user/2` and
`on_mount :require_admin`), `AdminLive.Users` (32 — including that demoting an admin severs their
live sockets, that deleting one does too, and that the actions are refused and visibly disabled
out of sudo mode), `Consensus.Content` (18), `Consensus.Seeds` (17, including idempotency and the
zero-admins gate), `Consensus.BootCheck` (15, against real directories under a `tmp_dir`, including
a root-owned `-wal` sidecar beside a healthy database), the settings LiveView (15),
`ConsensusWeb.HomeLive` (13), `UserSessionController` (13),
`Consensus.Application` (11, asserting the supervision-tree shape — there is no
`release_command`, so that list is the only thing that migrates a release),
`HealthController` (10, including that
it answers 503 on a pending migration and on a missing table), the admin home-page editor (10),
`Consensus.Release` (8, against a
throwaway repo under the test's own `tmp_dir` — never the suite database — and pinning that
`migrate/0`, `seed/0` *and* `rollback/2` all preflight),
`Consensus.Accounts.UserNotifier` (8 — stand-in adapters that exit and that return `{:error, _}`,
neither of which `Swoosh.Adapters.Test` can reproduce), the router (4 — asserting that every
`/admin` route carries *both* the plug and the `on_mount` guard, since dropping either is a silent
hole), `Consensus.DeployConfig` (4 — `fly.toml` read as text, no database: `app` vs `PHX_HOST`,
`PORT` vs `internal_port`, `DATABASE_PATH` inside the mount, and the single-quoted shape `ci.yml`'s
`sed` expects), plus registration, log-in and confirmation.

Note that `mix precommit` and CI are **not** the same checks. `precommit` *rewrites* files
(`mix format`, `mix deps.unlock --unused`); [CI](.github/workflows/ci.yml) *asserts*
(`mix deps.get --check-locked`, `mix deps.unlock --check-unused`, `mix format --check-formatted`,
then `mix compile --warnings-as-errors` and `mix test`). Run both before pushing if you care about
a green pipe.

A second CI job (`docker`) builds the release image **and boots it, twice over, in two steps.**

The first step runs one container against a tmpfs `/data` owned by uid 65534 (how Fly presents an
empty volume to a release running as `nobody`) and asserts, in order:

1. `/health` answers `200 ok` — polled at `127.0.0.1`;
2. `/health` answers `200` again under `Host: $PHX_HOST`, read out of `fly.toml` rather than
   hardcoded. Only this request proves the `force_ssl` `paths: ["/health"]` exclusion works: the
   first poll used a Host that `config/prod.exs` already excludes by *name*, so it would stay green
   with `paths:` deleted, while Fly's checker sends the machine's real hostname;
3. a real LiveView websocket handshake on `/live/websocket` returns **101** with `Origin` set to
   `https://$PHX_HOST`. `check_origin` defaults to true in production and validates `Origin`
   against the endpoint's `:url` host (which comes from `PHX_HOST`), so a mismatch 403s every
   socket in an app whose every page is a LiveView — while `GET /` and `/health` both keep
   answering 200 and Fly calls the machine healthy;
4. exactly one bootstrap admin was seeded, over `bin/consensus rpc`;
5. the schema is then deliberately broken and `/health` must turn 503.

The second step is the upgrade rehearsal: it boots on a real named Docker volume, renames the
seeded admin, stops the container, rolls the newest migration back down with `bin/consensus eval`,
and boots again on the same volume. The second boot must report `/health` 200, log `== Migrated`,
and still hold exactly one admin *under its new name*. Nothing else in the repo has ever migrated a
database that already had rows in it — which is what every deploy after the first one does — and
the rename re-proves that `Consensus.Seeds` gates on "are there zero admins?" rather than on the
bootstrap username.

Together these are the only thing anywhere in this repo that exercises the boot-time migrator,
`Consensus.Seeds`, `Consensus.BootCheck` and the `:prod` half of `config/runtime.exs` — `mix test`
never starts a release. Do not reduce them to a plain `docker build`.

What that job *cannot* catch is `fly.toml` contradicting itself, because it feeds the container the
same `PHX_HOST` it then asserts against. `test/consensus/deploy_config_test.exs` covers that, in
milliseconds, on the pull request.

`ci.yml` itself triggers only on `pull_request` and `workflow_call` — `fly-deploy.yml` calls it as
its gate, so triggering on `push` too would run the whole matrix and the Docker build twice for
every merge.

---

## Deployment

The target is **one Fly.io machine with one Fly Volume**, SQLite living on that volume at
`/data/consensus.db`. That is a hard constraint, not a default: two machines mounting one volume
is impossible, and two machines with two volumes are two divergent databases — never
`fly scale count 2`, and `auto_stop_machines` stays `off` because a stopped machine takes the
database and every LiveView websocket down with it.

There is deliberately **no `[deploy] release_command`** in [`fly.toml`](fly.toml): a release
machine has no volume mounted, so it would migrate a throwaway database. Migrations run at boot
instead, from the supervision tree (see *Architecture* above) — the pattern Fly's own
[SQLite3 guide](https://fly.io/docs/elixir/advanced-guides/sqlite3/) prescribes.

`fly.toml` does carry a `[[http_service.checks]]` block — a **`GET /health`** every 30s, 5s
timeout, after a 15s grace period. `fly deploy` watches a new machine for about ten seconds and
then stops watching; the health check is what notices afterwards. The grace period has to cover
boot-time migrations and seeding, which measure well under a second on a fresh database.

**It must not point at `/`.** Fly's checker connects over plain HTTP to the machine's *private*
address, and `force_ssl` in [`config/prod.exs`](config/prod.exs) 301-redirects everything that is
not on its exclusion list — on which `/health`, and only `/health`, sits. A check on `/` would
answer 301 forever and Fly would mark the machine permanently unhealthy. On a single-machine
deployment that machine is also the database, so this is not a cosmetic misconfiguration.

[`ConsensusWeb.HealthController`](lib/consensus_web/controllers/health_controller.ex) does not
merely answer 200. It runs two checks: `Ecto.Migrator.migrations/3` must report no `:down`
migration (else `503 migrations pending`), and then `SELECT 1 FROM users LIMIT 1` must succeed
(else `503 database unavailable`). A plain `SELECT 1` is not enough — it is a constant expression
SQLite answers without opening a table, so a release whose boot-time migrator never ran would
report healthy while `GET /` returned 500. The trade-off is deliberate: a 503 pulls the only
machine out of Fly Proxy rotation, turning a broken database into a visible outage rather than a
site that quietly 500s. See [docs/decisions.md](docs/decisions.md) D-018.

First-time setup (app name, `SECRET_KEY_BASE`, the volume, the `FLY_API_TOKEN` GitHub secret) is
in [TODO.md](TODO.md), whose §7 is also the day-2 runbook — including *Restoring from a snapshot*,
a checkpointed procedure that necessarily **destroys and recreates the Machine**. A mount is bound
to a volume *ID* fixed when the Machine was created, not to the `[[mounts]] source` name, so no
`fly deploy` and no `fly apps restart` can re-point an existing Machine at a restored volume, and
creating a new volume with the same name does not reattach it. That procedure is written from
Fly's published guides and has never been executed against a live app. Command-level reference for
deploying, reading logs, `fly ssh console` and rollbacks, plus every `fly.toml` stanza with its
rationale, is in [.claude/skills/fly-io/SKILL.md](.claude/skills/fly-io/SKILL.md). None of it is
duplicated here.

**`fly.toml` has to agree with itself, and now it is checked.**
[`test/consensus/deploy_config_test.exs`](test/consensus/deploy_config_test.exs) reads the file as
text — no database, milliseconds, fails on the pull request — and asserts that `PHX_HOST` equals
`<app>.fly.dev`, that `PORT` equals `internal_port`, that `DATABASE_PATH` lies inside
`[[mounts]] destination`, and that `PHX_HOST` is a single-quoted scalar (the shape `ci.yml`'s `sed`
depends on). `fly.toml`'s own header tells you to change `app` and then make `PHX_HOST` match; that
was two edits with nothing checking them. If you deliberately serve this app from a custom domain,
**edit** that first test and record the decision in [docs/decisions.md](docs/decisions.md) — do not
delete it. See D-023.

Continuous deployment is [.github/workflows/fly-deploy.yml](.github/workflows/fly-deploy.yml):
it calls `ci.yml` as a gate, then runs `flyctl deploy --remote-only --ha=false` under a
`deploy-group` concurrency lock. `--ha=false` is what keeps it at one machine.

---

## Repo layout

```
.
├── AGENTS.md                    # Phoenix/Elixir usage rules for coding agents
├── CLAUDE.md                    # project context read at the start of every AI session
├── Dockerfile                   # phx.gen.release --docker output + one added block: mkdir/chown /data
├── fly.toml                     # one machine, one volume, no release_command
├── mix.exs                      # aliases: setup, ecto.setup, ecto.reset, assets.*, precommit
├── .github/workflows/
│   ├── ci.yml                   # deps check, format, warnings-as-errors, test, then a
│   │                            #   docker job: build, boot + smoke test, boot twice on
│   │                            #   one volume
│   └── fly-deploy.yml           # calls ci.yml, then flyctl deploy
├── .claude/skills/              # elixir, phoenix, sqlite, fly-io
├── assets/                      # app.css (Tailwind + daisyUI), app.js, vendored heroicons/topbar
├── config/                      # config, dev, test, prod, runtime
├── docs/
│   ├── PRD.md                   # product north star (the voting product, not yet built)
│   ├── decisions.md             # ADR-lite technical log
│   ├── open-questions.md
│   ├── plans/                   # per-feature implementation plans
│   ├── prd-technical-extracts.md    # unratified draft
│   └── technical-roadmap-v1-draft.md # unratified draft
├── lib/
│   ├── consensus/               # Accounts, Content, Seeds, Release, Repo, Application, BootCheck
│   │   ├── accounts/            # user.ex, scope.ex, user_token.ex, user_notifier.ex
│   │   ├── boot_check.ex        # DATABASE_PATH/volume preflight, run before Consensus.Repo
│   │   └── content/             # home_page.ex
│   └── consensus_web/
│       ├── components/          # core_components.ex, layouts.ex, layouts/root.html.heex
│       ├── controllers/         # user_session_controller.ex, health_controller.ex,
│       │                        #   error_html/json
│       ├── live/                # home_live.ex, admin_live/, user_live/
│       ├── router.ex
│       └── user_auth.ex         # plugs + on_mount hooks; all authorization lives here
├── priv/repo/
│   ├── migrations/              # users+tokens (with username/is_admin), home_page singleton
│   └── seeds.exs                # delegates to Consensus.Seeds.run!/0
├── rel/overlays/bin/            # server (release entrypoint; sets PHX_SERVER=true) and
│                                #   migrate, plus their .bat pairs. migrate is generator
│                                #   output and is NOT in the deploy path — migrations run
│                                #   from the supervision tree; see Deployment.
└── test/                        # mirrors lib/, plus support/ (ConnCase, DataCase, fixtures)
                                 #   and deploy_config_test.exs, which reads fly.toml as text
```
