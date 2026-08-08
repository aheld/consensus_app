---
name: fly-io
description: Deploys and operates the Consensus Phoenix app on Fly.io — `fly deploy`, the committed `fly.toml` and what each stanza is for, the SQLite Fly Volume `consensus_data` mounted at `/data`, `DATABASE_PATH`, why there is no `[deploy] release_command` and migrations run at boot instead, `fly secrets set SECRET_KEY_BASE`, `PHX_HOST`/`PORT`, the never-more-than-one-machine rule, `auto_stop_machines`, the `Swoosh.Adapters.Logger` production mailer, `fly logs`/`status`/`ssh console`/remote IEx, rollbacks, volume snapshots and restore, and the GitHub Actions deploy workflow. Use this whenever the task involves deploying, releasing, rolling back, debugging production, reading production logs, provisioning or restoring a volume, setting secrets or env vars, editing `fly.toml` or the `Dockerfile` for production, or diagnosing "database is locked", "unable to open database file", a missing `SECRET_KEY_BASE`, migrations that did not run, mail that exits in a release, or a LiveView websocket that will not connect in production.
---

# Fly.io for Consensus

One machine, one volume, SQLite on that volume, migrations at boot. The deployment is
already configured and committed — this skill describes what is there, not how to create it.

Rationale lives in `docs/decisions.md`: **D-012** (one machine / one volume / never
auto-stopped, plus the Dockerfile `/data` block), **D-013** (WAL + `busy_timeout`), **D-014**
(the production mailer), **D-016** (the boot preflight, the removal of `VOLUME /data`, the
health check, and the CI trigger split). First-time setup is **`TODO.md`** — account, app,
volume, secrets, first deploy, CD token, verification. Follow it rather than improvising; it
is not duplicated here.

Platform behaviour is checked against `scratchpad/refs/fly-official.md`, a transcription of
the official [SQLite3 on Fly](https://fly.io/docs/elixir/advanced-guides/sqlite3/),
[fly.toml](https://fly.io/docs/reference/configuration/),
[Volumes](https://fly.io/docs/volumes/overview/),
[Snapshots](https://fly.io/docs/volumes/snapshots/),
[Autostop](https://fly.io/docs/launch/autostop-autostart/),
[GH Actions CD](https://fly.io/docs/launch/continuous-deployment-with-github-actions/) and
[Rollback](https://fly.io/docs/blueprints/rollback-guide/) pages. Not this skill: local dev
(`elixir`, `sqlite` skills); anything Postgres — no Postgres app, no `DATABASE_URL`, and
`fly launch`'s offer to provision one is wrong here; LiteFS, multi-region, or a second
machine (rejected in D-012).

## What is already in the repo

| File | What it is |
|---|---|
| `fly.toml` | Committed and tuned. **Do not regenerate it.** Annotated below. |
| `Dockerfile` | `mix phx.gen.release --docker` output plus one deliberate deviation (below). |
| `.dockerignore` | Excludes `/docs/`, `/.claude/`, `/.github/`, `*.md` (except README) and `*.db` / `*.db-shm` / `*.db-wal` — a dev database can never be baked into the image. |
| `rel/overlays/bin/{server,migrate}` | `PHX_SERVER=true exec ./consensus start` (the `CMD`) and `exec ./consensus eval Consensus.Release.migrate` (manual use only). |
| `lib/consensus/application.ex` | `preflight!/0`, then `{Ecto.Migrator, …}` then `{Consensus.Seeds, …}`, all before the endpoint. `children/0`, `skip_migrations?/0` and `skip_seeds?/0` are public so `test/consensus/application_test.exs` can assert the shape. |
| `lib/consensus/boot_check.ex` | `Consensus.BootCheck.run!/0,1` and `on_root_filesystem?/1` — the preflight itself, called from both `Application.start/2` and `Consensus.Release`. |
| `lib/consensus/release.ex` | `migrate/0`, `seed/0`, `rollback/2` for `bin/consensus eval`. **All three** preflight, through a private `preflight!/1` that passes the repo's own configured `:database` to `BootCheck.run!/1`. |
| `lib/consensus_web/controllers/health_controller.ex` | `GET /health` — what `[[http_service.checks]]` probes. Asserts no `:down` migrations **and** reads a real table, so a machine whose volume vanished (or whose migrator never ran) reports unhealthy. |
| `.github/workflows/{ci,fly-deploy}.yml` | `ci.yml` is `test` (Elixir 1.20.3 / OTP 29.0.5) + `docker`, triggered on `pull_request` and `workflow_call` only; `fly-deploy.yml` triggers on push to `main`, calls `ci.yml` as its gate, then runs `flyctl deploy --remote-only --ha=false`. The `docker` job **builds *and boots*** the release image — see "The `docker` job actually boots the image" below. |
| `test/consensus/deploy_config_test.exs` | Asserts `fly.toml` agrees with itself: `PHX_HOST == app <> '.fly.dev'`, `PORT == internal_port`, `DATABASE_PATH` inside `[[mounts]] destination`. Editing `fly.toml` carelessly fails `mix test` on a pull request. |

There is **no** `[deploy]` stanza, **no** top-level `[checks]` table and no `[processes]`
table. There **is** an `[[http_service.checks]]` block, and it points at a real `/health`
route — see "The health check".

`flyctl` is installed (v0.4.79 at time of writing). Elixir is in `/opt/homebrew/bin`; prefix
agent shell invocations with `export PATH="/opt/homebrew/bin:$PATH"` to run `mix`.

## fly.toml, annotated

The whole committed file, with its comments stripped (every key and value below is
byte-for-byte what `fly.toml` contains — re-diff with
`grep -v '^\s*#' fly.toml | grep -v '^\s*$'` before trusting it):

```toml
app = 'consensus-app'
primary_region = 'iad'
swap_size_mb = 512
kill_signal = 'SIGTERM'
kill_timeout = '30s'

[build]

[env]
  PHX_HOST = 'consensus-app.fly.dev'
  PORT = '8080'
  DATABASE_PATH = '/data/consensus.db'

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = 'off'
  auto_start_machines = false
  min_machines_running = 1
  processes = ['app']

  [[http_service.checks]]
    grace_period = '15s'
    interval = '30s'
    timeout = '5s'
    method = 'GET'
    path = '/health'

  [http_service.concurrency]
    type = 'connections'
    soft_limit = 200
    hard_limit = 250

[[mounts]]
  source = 'consensus_data'
  destination = '/data'
  initial_size = '1gb'
  snapshot_retention = 30
  auto_extend_size_threshold = 80
  auto_extend_size_increment = '1gb'
  auto_extend_size_limit = '10gb'

[[vm]]
  size = 'shared-cpu-1x'
  memory = '512mb'
  cpu_kind = 'shared'
  cpus = 1
```

- `app` / `primary_region` are placeholders until the operator claims a real name.
  `primary_region` is more than latency: `min_machines_running` applies **only** in the
  primary region, and the volume must live in the same region as the machine.
- `swap_size_mb` — on `shared-cpu-1x`/512 MB with one machine, an OOM kill is a full outage;
  swap turns it into slowness.
- `kill_signal` / `kill_timeout` — Fly defaults to `SIGINT` and 5 seconds. `SIGTERM` plus 30s
  lets the BEAM drain requests and close SQLite cleanly (WAL checkpoint), not die mid-write.
- `[build]` is empty on purpose, so `fly deploy` falls through to `Dockerfile` in the working
  directory.
- `[env]` values must be strings and names cannot begin with `FLY_`; secrets override `[env]`.
  `PHX_HOST` must match the public hostname or `runtime.exs` falls back to `"example.com"`.
  `PORT` must equal `internal_port` — `runtime.exs` reads `System.get_env("PORT", "4000")`.
  `DATABASE_PATH` **raises** if unset and must name a file inside the mount. `POOL_SIZE` is
  deliberately absent: `runtime.exs` defaults it to `"5"`, and SQLite serialises writes, so
  extra slots only help readers (D-013).
- Fly's defaults for a new app are `auto_stop_machines = "stop"` / `auto_start_machines =
  true`. Both are off here because a stopped machine drops every open LiveView websocket
  **and** takes the database offline, and cold-start latency would land on the first click of
  a shared link. The docs are explicit that the two must be both enabled or both disabled —
  `"stop"` with `auto_start_machines = false` gives a machine that never comes back.
- `[[http_service.checks]]` is the only health check (D-016). It is a `GET /health` on the
  service — **not `/`**, which could never pass because of `force_ssl`; see "The health check"
  below. Its `grace_period = '15s'` is what covers boot-time migrations and seeding — those
  measure well under a second on a fresh database, so 15s is deliberate slack. Without it,
  nothing watches the app after `fly deploy`'s ~10s smoke window closes.
- `type = 'connections'` because idle LiveView websockets are connections, not requests, and
  the proxy judges spare capacity from `soft_limit`.
- `[[mounts]] source` is the volume name — Fly volume names allow **only alphanumerics and
  underscores**, which is why it is not `consensus-data`. `destination` must contain
  `DATABASE_PATH`. Fly's default snapshot retention is 5 days; 30 is long enough to notice
  silent corruption over a long weekend. `auto_extend_size_increment` and
  `auto_extend_size_limit` must be set together; the threshold is a percentage.
- `[[vm]]` is explicit so a flyctl default change cannot silently resize production.

### What you may change / what you must not

**The operator edits exactly three values** (TODO.md §2.3):

| Value | Current | Rule |
|---|---|---|
| `app` | `'consensus-app'` | Globally unique Fly app name. |
| `primary_region` | `'iad'` | From `fly platform regions`; the volume goes in the same one. |
| `[env] PHX_HOST` | `'consensus-app.fly.dev'` | Exactly the public hostname — `<app>.fly.dev`, or a custom domain if attached. Change it in the *same commit* as `app`: `test/consensus/deploy_config_test.exs` asserts `PHX_HOST == app <> '.fly.dev'` and will fail the pull request otherwise. If you attach a custom domain, that test is the thing to update deliberately, not to work around. |

Everything else has a reason. Do not change without a new `docs/decisions.md` entry:

- `PORT` / `internal_port` — must stay equal, both `8080`.
- `DATABASE_PATH` — must stay inside `[[mounts]] destination`.
- `[[mounts]] source` / `destination` — `fly deploy` cannot swap a live machine's mount;
  changing these means destroying and recreating the machine.
- `auto_stop_machines` / `auto_start_machines` / `min_machines_running` — move as a set.
- `kill_signal` / `kill_timeout`, `swap_size_mb`, `[[vm]]` sizing, `snapshot_retention`, the
  auto-extend trio, and the `[[http_service.checks]]` block (D-016).
- Do not add `[deploy]`. Do not add `strategy = "bluegreen"` — impossible with a mounted
  volume; a single machine is necessarily a stop-then-start, so expect seconds of downtime
  per deploy.

Changes must be **committed and pushed**: CI deploys the `fly.toml` in the repository, not
the one on your laptop.

## Migrations: no release_command, migrate at boot

Fly volumes are unavailable during image build **and during release-command execution** — the
release command runs in a temporary machine with no volume, so
`release_command = "/app/bin/migrate"` would migrate a throwaway database and leave the real
one untouched. The SQLite3 guide says it directly: *"a volume may not be ready once your
application release runs, so to fix this we need to run migrations on application start."*

So migrations run at boot, from the supervision tree in `lib/consensus/application.ex`.
`Application.start/2` first calls a private `preflight!/0`, which delegates to
`Consensus.BootCheck.run!/0` (D-016) unless `skip_migrations?/0`, then builds the tree — the
list is `Consensus.Application.children/0`, public so it can be asserted in a test:

```elixir
children = [
  ConsensusWeb.Telemetry,
  Consensus.Repo,
  {Ecto.Migrator,
   repos: Application.fetch_env!(:consensus, :ecto_repos), skip: skip_migrations?()},
  {Consensus.Seeds, skip: skip_seeds?()},
  # … DNSCluster, Phoenix.PubSub …
  ConsensusWeb.Endpoint
]
```

`{Consensus.Seeds, …}` sits **immediately after** the migrator. Both run synchronously during
supervisor init and return `:ignore`, so by the time `ConsensusWeb.Endpoint` starts the schema
is current and the bootstrap admin exists. `skip_migrations?/0` returns `true` when
`RELEASE_NAME` is unset — migrations run in a release (on Fly), skipped under plain `mix`. Do
**not** also call `Consensus.Release.migrate()` from `start/2`; the older SQLite3 guide says
to, but with the `Ecto.Migrator` child present that migrates twice. A failing boot migration
surfaces as a failed deploy in the ~10s smoke check — desired, so do not add `--detach`.
Manual paths:

```sh
fly ssh console -C "/app/bin/migrate"
fly ssh console -C "/app/bin/consensus eval 'Consensus.Release.seed()'"
fly ssh console -C "/app/bin/consensus eval 'Consensus.Release.rollback(Consensus.Repo, 20260808033720)'"
```

### The boot preflight (D-016)

**It lives in its own module, `Consensus.BootCheck` (`lib/consensus/boot_check.ex`).**
`Application.start/2` calls a private `preflight!/0` — `if skip_migrations?(), do: :ok, else:
Consensus.BootCheck.run!()` — so at boot it runs in a release only, never under plain `mix`, and
before `Consensus.Repo` is in the tree. **All three `Consensus.Release` entry points —
`migrate/0`, `seed/0` and `rollback/2` — preflight unconditionally**, because those run in a
fresh node via `bin/consensus eval` and would otherwise skip it, and they are precisely what you
reach for when something is already wrong. They go through a private `preflight!/1` that passes
the repo's *own* configured `:database` to `BootCheck.run!/1`, so a repo handed to `rollback/2`
by name is checked against the file it will actually open. Public surface: `run!/0` (reads the
repo config, `:ok` if there is none), `run!/1` (an explicit path), `on_root_filesystem?/1`.

Three checks, in order:

1. **The directory exists** — `File.mkdir_p` it if not.
2. **The directory is writable** — write and delete a `.consensus-write-probe`.
3. **The whole existing WAL set is writable** — `DATABASE_PATH` **and** its `-wal` and `-shm`
   sidecars, each opened for `:append`, skipping the ones that do not exist yet (on a first
   boot none do; after a clean shutdown the sidecars are checkpointed away). This catches a
   root-owned `consensus.db` sitting on a perfectly writable `/data`, which the directory probe
   alone would miss — and, because `runtime.exs` pins `journal_mode: :wal`, a sidecar whose
   ownership differs from the database's, which a `DATABASE_PATH`-only probe would walk
   straight past. The raised message names **the path that actually refused**, not just
   `DATABASE_PATH`.

   Worth knowing before you go hunting for the cause: running `sqlite3` as root over
   `fly ssh console` is *not* how a mismatched sidecar happens — SQLite fchowns a journal it
   creates to match the database file's owner. The reachable causes are a root
   `cp`/`tar`/snapshot restore that preserves its own ownership, a non-SQLite root process
   writing a sidecar path, or root having created the database in the first place.

Any of those failing raises `Cannot write the SQLite database (<reason>).`, quoting
`DATABASE_PATH`, the directory's **and the file's** `type, uid:gid, mode` from `File.stat/1`,
the release user (`nobody`, uid 65534), and the fix:

```
fly ssh console -u root -C "chown -R 65534:0 /data"
```

D-016 records what this replaced: on a root-owned volume the release used to emit eleven
`database_open_failed` lines and then a `DBConnection.ConnectionError` about connection pools,
which sent the operator reading about `POOL_SIZE`. Now it dies with the one message. The
Dockerfile's `chown` only bites when the mount is empty, so a restored snapshot, a
`lost+found`, or a file written during a root `fly ssh console` session all defeat it — this
preflight is what turns those into an instruction.

**Then it checks the directory is actually a mount**, via `on_root_filesystem?/1`, which
compares `File.stat/1`'s `major_device` for the directory against `/`'s. Equal means
`DATABASE_PATH` resolves into the container filesystem, so the database is thrown away by the
next deploy — the one misconfiguration `fly.toml` calls fatal, and the one with no error message
of its own. **On Fly this raises and fails the deploy**; the gate is `FLY_APP_NAME` being set.
That is deliberate: there is no legitimate reason for `DATABASE_PATH` to sit outside the mount
on Fly, and the database is empty by definition at that point, so failing costs nothing.
Everywhere else it is only a `Logger.warning`, which is what lets a local `docker run` with no
`-v` still boot for a quick look. Either way the message begins
`<dir> is not a mount point — it is part of the container filesystem.` and points at
`fly volumes list` / `[[mounts]] destination` — grep `fly logs` for `is not a mount point`
right after a deploy; it is much cheaper than TODO.md §6's durability test.
`on_root_filesystem?/1` returns `false` when either path cannot be stat'd, so an unknown answer
never fails a boot.

## The Dockerfile's one deviation from the generator

Everything in `Dockerfile` is `mix phx.gen.release --docker` output except this line, added
immediately before `ENV MIX_ENV="prod"` / `USER nobody` (D-012):

```dockerfile
RUN mkdir -p /data && chown nobody:root /data && chmod 750 /data
```

When a volume is mounted empty, both Docker and Fly's init take the mount point's ownership
**from the image**. Without this the release starts as `nobody` against a root-owned `/data`
and dies (now via the preflight above; previously with
`** (Exqlite.Error) unable to open database file`).

**There is deliberately no `VOLUME /data`** — it was removed in D-016 and a comment in the
Dockerfile says why. `VOLUME` makes Docker invent an anonymous volume for a plain
`docker run`, so a local run with **no** `-v` looked durable while writing to a throwaway.
That is the exact misconfiguration `fly.toml` calls fatal, and it made TODO.md §6's local
durability check meaningless. Without it, forgetting the mount fails visibly and
`docker rm` honestly loses the data. Do not add it back.

Also true of this Dockerfile:

- The builder installs `git` because `mix.exs` pulls `heroicons` and `daisyui` as GitHub
  deps; a builder with no route to GitHub fails at `mix deps.get`.
- `ecto_sqlite3` compiles the `exqlite` NIF against glibc. **Never switch `RUNNER_IMAGE` to
  Alpine**; keep builder and runner on the same Debian tag (`trixie-20260803-slim` today).
- `CMD ["/app/bin/server"]` is what sets `PHX_SERVER=true`; change it to `bin/consensus start`
  and the release boots with no web server. (`RELEASE_NAME` — which gates migrations — is set
  by the release's own `bin/consensus` script, so it survives that mistake; it is only unset
  when the app is started outside the release, e.g. under `mix`.)
- `ELIXIR_VERSION` / `OTP_VERSION` are mirrored in `ci.yml`'s matrix — change both together.

## Secrets and environment

Secrets are runtime-only, invisible to the Docker build, and override `[env]`.
`fly secrets set` redeploys/restarts the machine unless you pass `--stage` — on one machine
that is seconds of downtime plus a fresh boot-migration pass.

```sh
fly secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)"
fly secrets set ADMIN_PASSWORD='…' ADMIN_EMAIL='…'
fly secrets list      # names, digests and deployment status — never values
fly secrets unset SOME_KEY
```

| Var | Where | Notes |
|---|---|---|
| `SECRET_KEY_BASE` | secret | Required; `runtime.exs` raises without it. Never in `[env]`. |
| `ADMIN_USERNAME` / `ADMIN_EMAIL` / `ADMIN_PASSWORD` | secrets | Read by `Consensus.Seeds` on **every** boot. Set `ADMIN_PASSWORD` before the first deploy — seeding never modifies an existing user, so setting it later does nothing. |
| `PHX_HOST`, `PORT`, `DATABASE_PATH` | `[env]` | Required, not secrets. See the `fly.toml` notes above. |
| `POOL_SIZE`, `DNS_CLUSTER_QUERY` | unset | Read by `runtime.exs`; `POOL_SIZE` defaults to `5`, and clustering is pointless on one machine. |
| `PHX_SERVER`, `RELEASE_NAME` | set by the release | Do not set by hand; do not change `CMD`. |
| `DATABASE_URL` | **never** | No Postgres in this app. |

`runtime.exs` binds `ip: {0, 0, 0, 0, 0, 0, 0, 0}`. Fly Proxy reaches the machine on its
private IPv6 address; a loopback bind makes the app unreachable.

## The production mailer (D-014)

`config/runtime.exs` pins, inside the `:prod` block:

```elixir
config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Logger, level: :info
```

Load-bearing, not cosmetic. `config/config.exs` names `Swoosh.Adapters.Local` and
`config/prod.exs` sets `config :swoosh, local: false`, which stops Swoosh starting the local
storage process. In a release the two together make every delivery **exit**:

```
** (exit) exited in: GenServer.call({:global, Swoosh.Adapters.Local.Storage.Memory}, {:push, %Swoosh.Email{...}}, 5000)
```

An `exit` is not caught by `with`, so it propagates and takes the calling LiveView down — a
real bug, reproduced against the built image before the fix. `Swoosh.Adapters.Logger` always
returns `{:ok, _}`, needs no process, and logs the recipient only, so no magic-link token
reaches `fly logs`. `Consensus.Accounts.UserNotifier` additionally catches both `{:error, _}`
and process exits and logs `could not deliver …` at `:error`.

Operationally: **this app sends no real email in production.** Password log-in is the
supported path; magic-link log-in and email-change confirmation are logged, not delivered.
That has a recovery consequence worth knowing before you get the support request: because no
magic link is deliverable, a forgotten password has no self-service route back in, and
`users.email` is unique so the person cannot re-register either. The lever on a mail-less
deployment is the **Delete** button in `/admin/users` (`Accounts.delete_user/2`, D-015), which
frees the email address and username. It refuses to delete an administrator — demote first —
and refuses self-deletion, so keep a second admin if you want that path to exist at all.
A real provider is a one-line change in the "Configuring the mailer" section of
`config/runtime.exs` (its commented Mailgun example expects `MAILGUN_API_KEY` /
`MAILGUN_DOMAIN` as Fly secrets), placed after the Logger line so it wins.

## Deploying, and the one-machine rule

```sh
fly deploy --ha=false                 # --ha defaults to true; false keeps it at one machine
fly deploy --remote-only              # remote building is already the default
fly deploy --local-only               # build with the local Docker daemon
fly deploy --now                      # skip the confirmation prompt
fly scale show                        # `fly scale count 1` is the only correct count
```

`fly deploy` uploads the build context, builds `Dockerfile`, pushes the image, replaces the
machine, then watches it ~10 seconds (smoke checks). `--ha=false` is what stops flyctl
creating a spare machine — and a spare cannot mount this volume.

**Never `fly scale count 2`.** Fly's resilience blueprint recommends ≥2 machines; that cannot
apply to a single-file SQLite database. A second machine gets a *different* volume and a
*different, silently divergent* database, and the proxy would split users between them. Fly's
volumes page states the exposure this accepts: *"Running an app with a single Machine and
volume leaves you at risk for downtime and data loss."* D-012 accepts it explicitly; the exit
is a networked database, not a second machine.

CI does the same on every push to `main`. `fly-deploy.yml` triggers on `push: branches: [main]`
plus `workflow_dispatch`, declares `permissions: contents: read` (nothing in it writes to the
repository), and runs the whole of `ci.yml` as a reusable workflow via `uses:` — so both its
`test` and `docker` jobs must be green, and the `docker` job includes the boot smoke test, so
a release that fails to boot can no longer reach Fly — then `flyctl deploy --remote-only --ha=false`
with `FLY_API_TOKEN` from repository secrets, under
`concurrency: {group: deploy-group, cancel-in-progress: false}` so two deploys can never race
the one volume. Token creation and `gh secret set` are TODO.md §5.

`ci.yml` itself is triggered by `pull_request` and `workflow_call` **only** — deliberately not
by `push` to `main` (D-016), because `fly-deploy.yml` already calls it and a push would
otherwise run the matrix and the Docker build twice. Both workflows are on
`actions/checkout@v5`.

What has to pass before a deploy starts, transcribed from `ci.yml`. Job `test`
(Elixir 1.20.3 / OTP 29.0.5, `MIX_ENV=test`), in order: `mix deps.get --check-locked`,
`mix deps.unlock --check-unused`, `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix test`. **`mix precommit` is not this** — it *rewrites*
files (`format`, `deps.unlock --unused`) instead of asserting, never runs `--check-locked`, and
never touches the image, so a locally-green `precommit` can still red-light the deploy.

### The `docker` job actually boots the image — it is not `docker build`

This is the deploy gate that matters most to *this* skill, and it has been described wrongly
here before. `mix test` never starts a release, so the `docker` job is the **only** thing in
the repo that exercises the boot-time `{Ecto.Migrator, …}` child, `Consensus.Seeds`,
`Consensus.BootCheck.run!/0` and the `config_env() == :prod` half of `config/runtime.exs`. A
build-only job is what let a `/health` regression deploy green.

It runs in parallel with `test`, and after checkout + `docker/setup-buildx-action@v3` it does
three things:

1. **Build** — `docker/build-push-action@v6`, `context: .`, `push: false`, **`load: true`**,
   **`tags: consensus:ci`**, `cache-from/to: type=gha`. `load: true` is what puts the image in
   the local daemon so it can be *run*; without it the next two steps have nothing to start.
2. **Boot the release image and smoke test it.** `PHX_HOST` is read out of `fly.toml` with
   `sed` (not hardcoded), the container runs against `--tmpfs /data:rw,mode=0750,uid=65534,gid=0`
   — how Fly presents an *empty* volume to a release running as `nobody` — and then five
   assertions:
   - `GET /health` on `127.0.0.1` polls up to 60 s for body `ok`;
   - `GET /health` **again under `Host: $phx_host`**, expecting 200;
   - a real **LiveView websocket upgrade** (`/live/websocket?vsn=2.0.0`, with
     `Origin: https://$phx_host` and `x-forwarded-proto: https`), expecting **101**;
   - `Consensus.Accounts.count_admins() == 1` over `docker exec … /app/bin/consensus rpc`;
   - the schema broken over `rpc` (`ALTER TABLE users RENAME TO users_gone`), then `/health`
     must answer **503**.
3. **Boot twice on one volume, migrating a populated database.** Boots `consensus:ci` against
   a real named Docker volume, renames the seeded admin over `rpc`, rolls the newest migration
   back down with `bin/consensus eval`, then boots again — so the second boot faces a genuinely
   pending migration against a *populated* `users` table. It must report `/health` 200, log
   `== Migrated`, and still show exactly one admin **still carrying the new name** (the
   assertion that `Consensus.Seeds` gates on "zero admins?" and not on the bootstrap username).

A `Release logs` step (`if: always()`) dumps `docker logs` for all three containers, then a
teardown removes them and the volume. Budget 30–60 s.

**Why assertion two is not redundant with the poll.** The poll goes to `Host: 127.0.0.1`, which
`config/prod.exs` already excludes from `force_ssl` by **host** — so it would stay 200 even if
`paths: ["/health"]` were deleted from the `exclude:`. Fly's checker sends the machine's own
hostname, never `127.0.0.1`, so only the hostname-carrying request proves the check can ever go
green in production. For the same reason, **do not boot a local reproduction with
`-e PHX_HOST=localhost`**: it is a convenient lie that hides both this and a `PHX_HOST` that
disagrees with the real hostname (which 403s every socket upgrade while `GET /` and `/health`
keep answering 200, so Fly reports the machine healthy and the app is dead).

The step feeds the container the same `PHX_HOST` it then asserts against, so it *cannot* catch
`fly.toml`'s `app` and `PHX_HOST` drifting apart. That is
`test/consensus/deploy_config_test.exs`'s job — it reads `fly.toml` as text and asserts
`PHX_HOST == app <> ".fly.dev"`, `PORT == internal_port` and `DATABASE_PATH` inside
`[[mounts]] destination`, on a pull request, in milliseconds, with no database.

Reproducing the whole `docker` job locally — build, boot, and all five assertions — is written
out step by step in the **`elixir` skill**, under "Reproducing CI locally, completely". Use
that; `docker build -t consensus:ci .` on its own reproduces one of the three steps.

## The health check

`fly.toml` carries exactly one, an `[[http_service.checks]]` block added in D-016:
`grace_period = '15s'`, `interval = '30s'`, `timeout = '5s'`, `method = 'GET'`,
`path = '/health'`. `fly checks list` reports it. There is still no top-level `[checks]`
table.

Why it exists: `fly deploy`'s smoke check watches the machine for about ten seconds and then
stops watching. That smoke window is meaningful (the `Endpoint` is the *last* supervision
child, so a listening socket on 8080 proves migrations and seeding already succeeded), but it
says nothing about minute eleven. `grace_period` has to outlast boot migrations and seeding,
which is why it is 15s rather than the 10s in Fly's own example.

**Three files have to agree, and each one carries a comment saying so.** Change one and the
machine silently never reports healthy:

| File | What it must say |
|---|---|
| `fly.toml` | `[[http_service.checks]]` → `path = '/health'` |
| `lib/consensus_web/router.ex` | `get "/health", HealthController, :index` in a `scope "/"` with **no** `pipe_through` |
| `config/prod.exs` | `force_ssl: [..., exclude: [paths: ["/health"], hosts: [...]]]` |

*Why not `path = '/'`.* Fly's checker connects over plain HTTP to the machine's private
address, supplying neither `x-forwarded-proto: https` nor a `Host` of `localhost` /
`127.0.0.1`. `Plug.SSL` therefore does not consider the request secure and answers **301**, so
a check on `/` could never return 200 — no matter how healthy the app is. The `paths:`
exclusion is what makes `/health` reachable; the `hosts:` entries next to it are the
generator's and are unrelated.

*Why a controller rather than a bare route.* A static 200 would keep reporting healthy on a
machine whose volume had gone away — the single most likely failure this deployment has. So
`ConsensusWeb.HealthController.index/2` checks two things, and **neither of them is a bare
`SELECT 1`**:

1. **No pending migrations.** `Ecto.Migrator.migrations/3` must report no `:down` entry, else
   `503 "migrations pending"`. It is passed `skip_table_creation: true` so a check running every
   30 s never takes SQLite's single write lock (the default would
   `CREATE TABLE IF NOT EXISTS schema_migrations`). This closes a real hole: `SELECT 1` is a
   constant expression SQLite answers without opening a table, so a release whose boot-time
   `Ecto.Migrator` never ran would have returned 200 here while `GET /` returned 500 — and the
   deploy would have gone green.
2. **A real table is readable.** `SELECT 1 FROM users LIMIT 1`, the table name taken from
   `Consensus.Accounts.User.__schema__(:source)` at compile time so a rename cannot leave the
   check querying something gone. Correct on an empty table.

Anything else answers `503 "database unavailable"`, via **both** a `rescue` clause and a
`catch :exit, reason` clause — a dead or draining connection pool exits rather than raising, and
`rescue` does not catch an exit. The route sits outside the `:browser` pipeline deliberately: no
session, no CSRF token, no layout. Note the trade-off the moduledoc spells out: a 503 pulls the
single machine out of Fly Proxy rotation, so a broken database is a hard outage rather than a
site that quietly 500s. That is intended.

`test/consensus_web/controllers/health_controller_test.exs` guards the arrangement from the app
side. It **evaluates** `config/prod.exs` rather than grepping it —
`Config.Reader.read!("config/prod.exs", env: :prod, target: :host)`, then
`assert force_ssl[:rewrite_on] == [:x_forwarded_proto]` and
`assert "/health" in force_ssl[:exclude][:paths]` — and reads **`fly.toml` as text**, asserting
`[[http_service.checks]]` and `path = '/health'`. (It no longer carries a
`refute fly =~ "path = '/'"`; the positive assertion is the guard.) So editing either of those
files carelessly fails `mix test`, not production. Changing any of the three is worth a
`docs/decisions.md` entry.

## Observing the app

```sh
fly status                                            # machine state, region, current release
fly checks list                                       # the GET /health http_service check
fly logs                                              # streams; -n for buffer only
fly machine list ; fly machine status <machine-id>
fly ssh console                                       # shell on the machine
fly ssh console --pty -C "/app/bin/consensus remote"  # remote IEx on the running node
fly ssh issue --agent                                 # if ssh cannot authenticate
fly apps open                                         # `fly open` is a deprecated alias
fly config show --local --toml                        # parse the local fly.toml
```

On the machine: `ls -la /data` (expect `consensus.db`, `-wal`, `-shm`), `df -h /data`,
`env | grep -E 'DATABASE_PATH|PHX_HOST|PORT|RELEASE_NAME'`. The runtime image is Debian slim
running as `nobody`; there is **no `sqlite3` CLI** installed. From a remote IEx,
`Consensus.Repo.query!("PRAGMA journal_mode")` should return `"wal"` and
`Ecto.Migrator.migrations(Consensus.Repo)` lists every migration with `:up`/`:down`.
`/admin/dashboard` (LiveDashboard, admin-only) is the fastest read on memory, processes and
Ecto queries without SSH.

## Rollbacks, snapshots, restore

```sh
fly releases --image     # release history including the Docker image reference
fly image show           # the image currently deployed
fly deploy --image registry.fly.io/<app>:deployment-<id> --ha=false
```

Rolling back the image does **not** roll back the database: boot migrations already ran and
are `:up`. Roll a migration back explicitly *first*, then deploy the older image. Write
migrations so a repeated boot is safe — the machine restarts on every deploy, every secret
change and every host event.

```sh
fly volumes list
fly volumes snapshots list <volume-id>
fly volumes snapshots create <volume-id>          # before any risky migration
fly volumes update <volume-id> --snapshot-retention 30
fly volumes create consensus_data --snapshot-id <snapshot-id> -s 1 --region <region>
```

Restoring always creates a **new** volume; it never writes back into the existing one. Since
`[[mounts]] source` is `consensus_data`, you must end up with exactly one volume by that name
attached to the machine — snapshot the bad one, `fly volumes destroy` it, recreate from the
snapshot under the same name, then `fly deploy --ha=false` or `fly apps restart <app>`.

Snapshots are block-level and **not transactionally consistent with the SQLite WAL**. For a
trustworthy backup, make a consistent file first from a remote IEx —
`Consensus.Repo.query!(~s|VACUUM INTO '/data/backup.db'|)`, from IEx rather than
`ssh console -C` because the shell eats the SQL string's single quotes — then pull it off-box
with `fly sftp get /data/backup.db ./consensus-prod-$(date +%F).db`.
The plain `fly sftp get /data/consensus.db ./prod.db` of TODO.md §7 is still better than
relying on a snapshot alone — it just copies the file mid-WAL.

## Common failure modes

**Machine boots then exits;** `** (RuntimeError) environment variable SECRET_KEY_BASE is
missing.` — `runtime.exs` raises before the supervision tree starts, and secrets are invisible
to the build, so this survives a green build. Fix with
`fly secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)"`, which redeploys. The sibling
`environment variable DATABASE_PATH is missing. For example: /etc/consensus/consensus.db`
means `[env] DATABASE_PATH` was removed or a different config file was deployed.

**Machine dies with `Cannot write the SQLite database (...)`** — the
preflight above did its job. `/data`, or `consensus.db` on it, is not writable by `nobody`. The
message prints both paths' real ownership and mode; run the
`fly ssh console -u root -C "chown -R 65534:0 /data"` it suggests and restart. Causes: a
restored snapshot, a `lost+found`, files written
during a root SSH session, or someone dropping the
`RUN mkdir -p /data && chown nobody:root /data && chmod 750 /data` line from the Dockerfile.
A bare `** (Exqlite.Error) unable to open database file` with no preflight message means the
preflight was bypassed — `RELEASE_NAME` unset, so the app was not started through the release
scripts.

**Database resets to empty on every deploy** — `DATABASE_PATH` points outside the mount
(e.g. `/app/consensus.db`), so it lives in the image layer. The boot preflight now **fails the
deploy** on Fly before you lose anything (it only warns off-Fly, where `FLY_APP_NAME` is unset):
grep `fly logs` for `is not a mount point`. Verify with
`fly ssh console -C "ls -la /data"`; TODO.md §6 has a durability test for exactly this.

**Deploy aborts on a volume/mount error, or flyctl offers to create a volume** — no volume
named `consensus_data` in `primary_region`, or it was created in another region or under a
hyphenated name (only alphanumerics and underscores are legal). Check `fly volumes list`;
create with `fly volumes create consensus_data --region <region> --size 1`. A *different*
message — *"If a Machine has a mounted volume, `fly deploy` can't be used to mount a different
one"* — means `[[mounts]]` changed after the machine existed.

**`** (Exqlite.Error) database is locked`** — `runtime.exs` sets `journal_mode: :wal` and
`busy_timeout: 5_000` in prod, so a contended write waits rather than failing. This means a
write held the lock over 5 seconds, or something else has the file open. Check `fly status`
for a second machine first; otherwise look for a long transaction or an `ssh console` session
holding the database.

**LiveView never connects; logs show `Could not check origin for Phoenix.Socket transport.`**
— `PHX_HOST` does not match the hostname in the browser's address bar, so `runtime.exs` built
`url: [host: "example.com", …]` and the origin check rejects the socket. Note how quiet this
failure is: `GET /` still answers 200 (LiveView static-renders on the dead-render pass) and
`/health` still answers 200 (origin-free, session-free, outside `:browser`), which is exactly
what `[[http_service.checks]]` polls — so Fly reports the machine healthy while every page in
the app is inert. Two guards now catch it before production: `deploy_config_test.exs` fails a
pull request when `app` and `PHX_HOST` disagree, and the `docker` job completes a real
websocket handshake and requires 101.

**Machine `started` but the URL times out or returns a Fly 502** — `PORT` ≠ `internal_port`,
or `runtime.exs` was edited to the commented-out loopback bind `{0, 0, 0, 0, 0, 0, 0, 1}`.

**Deploy succeeded but a new migration "did not run"** — `skip_migrations?/0` returns `true`
whenever `RELEASE_NAME` is unset, i.e. whenever the container was started outside the release
scripts rather than by `CMD ["/app/bin/server"]`. `fly logs` right after a deploy should show
`== Running … change/0 forward` or `Migrations already up`. Force one with
`fly ssh console -C "/app/bin/migrate"`.

**Boot fails with `could not seed the bootstrap admin user`** — `Consensus.Seeds` raises when
the database has zero users and the admin changeset is invalid; usually `ADMIN_EMAIL` or
`ADMIN_USERNAME` collides with an existing account. Read the changeset errors in the log.

**Registration or log-in crashes with `** (exit) exited in: GenServer.call({:global,
Swoosh.Adapters.Local.Storage.Memory}, …)`** — the `Swoosh.Adapters.Logger` line in
`config/runtime.exs` was removed, or a later line reinstated `Swoosh.Adapters.Local`. D-014.

**`fly checks list` shows the check failing on a machine that serves fine in a browser** —
almost never an app fault. Check the three files listed in "The health check" in this order:
(1) `fly.toml`'s `path` — if someone set it back to `'/'`, `force_ssl` answers the prober 301
and the check can never pass; (2) `config/prod.exs` — if `paths: ["/health"]` was dropped from
the `force_ssl` `exclude:`, same 301, same result; (3) the app itself — `/health` returns
**503 `migrations pending`** when a migration is still `:down` (look for the boot migrator in
`fly logs`) and **503 `database unavailable`** when `SELECT 1 FROM users LIMIT 1` fails or the
pool exits, which is the check doing its job, so go look at `/data` rather than at the check.
The two bodies are distinguishable, so read the response before guessing. `curl -i` from
`fly ssh console` against `http://localhost:8080/health` distinguishes a 301 from a 503 in one
command. Compare against `fly status` (machine `started`) before touching anything.

**Data vanished after a local `docker run` + `docker rm`** — expected since D-016 removed
`VOLUME /data`. A local run needs an explicit `-v`; without one the database is written to the
container filesystem and goes with the container. This is the honest behaviour, not a bug.

**Smaller ones.** First request after idle is slow or sessions vanish → `auto_stop_machines`
is no longer `'off'`; restore the trio. Build fails at `mix deps.get` with a git error →
`heroicons` and `daisyui` are GitHub deps and the builder needs GitHub reachable. CI `deploy`
fails to authenticate → `FLY_API_TOKEN` missing, expired, or pasted without its leading
`FlyV1 ` prefix. CI `deploy` never starts → the reusable `ci.yml` failed and `deploy` has
`needs: test`. CI deploys to the wrong app → `fly.toml` was edited but never committed.

## Commands verified against `flyctl` v0.4.79

Every flag above was checked with `--help` on this machine (read-only; no login, no mutation):
`fly deploy`, `fly secrets set|list|unset`, `fly logs`, `fly status`, `fly ssh console|issue`,
`fly sftp get`, `fly scale count|show`, `fly releases`, `fly image show`,
`fly volumes create|list|update|destroy`, `fly volumes snapshots list|create`,
`fly tokens create deploy`, `fly apps create|restart|open`, `fly machine list|status`,
`fly checks list`, `fly platform regions`, `fly config show|validate`. Notable results:
`--ha` defaults to **true** (hence `--ha=false` everywhere); `--remote-only` is already the
default, kept explicit in CI; `fly releases` needs `--image` to print the image reference used
for a rollback; `fly volumes create --size` defaults to **1** GB and `--snapshot-retention` to
**5** days; `fly tokens create deploy -x` defaults to `175200h0m0s` (20 years);
`fly secrets set --stage` sets a secret *without* redeploying; `fly open` prints a deprecation
notice pointing at `fly apps open`.
