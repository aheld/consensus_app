# Fly.io + Phoenix + SQLite — Official Documentation Reference

Ground-truth extract of the official Fly.io and Phoenix docs, fetched 2026-08-07.
Every command / config block below is reproduced as the source gives it. Where a
fetch returned only prose (no literal block), that is noted explicitly with
`[prose only — no literal block on the page]` so a later critic does not treat a
paraphrase as a citation.

Verbatim quotes from the docs are in `"double quotes"`.

---

## 1. SQLite3 on Fly.io (Elixir advanced guide) — THE critical one

Source: https://fly.io/docs/elixir/advanced-guides/sqlite3/

### Premise stated by the guide

- SQLite3 databases must live on a persistent Volume, because the deployment image is
  overwritten on each deploy.
- `"Volumes are limited to one host, this currently means that fly.io hosted Elixir
  applications that use SQLite3 for their database can't be deployed to multiple regions."`
- Multi-region sync alternative named: LiteFS — `"if you are okay using beta software,
  LiteFS could work for multi-region sync."`

### Create the volume

```
fly volumes create name
```

- `"Only alphanumeric characters and underscores are allowed in names."`
- `"The default volume size is 3 gigabytes."` (NOTE: the Volumes overview page says 1GB —
  see Contradictions.)
- Change size by adding a `--size int` argument.

### fly.toml — mount the volume

```toml
[mounts]
  source="name"
  destination="/mnt/name"
```

### fly.toml — remove the release command, add DATABASE_PATH

The `release_command` under `[deploy]` must be **removed**. Reason, verbatim:

> `"This step is required because a volume may not be ready once your application release
> runs, so to fix this we need to run migrations on application start."`

Replace it with an env var:

```toml
[env]
DATABASE_PATH = "/mnt/name/name.db"
```

### Run migrations at application start

Add to `lib/name/application.ex`:

```elixir
@impl true
def start(_type, _args) do
  Name.Release.migrate()
  children = [
```

### Converting an existing Phoenix app

The guide lists these conversion steps: update `.gitignore`; replace `:postgrex` with
`ecto_sqlite3` in `mix.exs`; update `config/dev.exs`; update `config/test.exs`; update
`config/runtime.exs` for production; update the Repo adapter in `lib/name/repo.ex`.

`mix.exs`:

```elixir
def deps do
  [
    {:ecto_sqlite3, "~> 0.9.1"},
  ]
end
```

`config/dev.exs`:

```elixir
config :name, Name.Repo,
  database: Path.expand("../name_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  show_sensitive_data_on_connection_error: true
```

`config/test.exs`:

```elixir
config :name, Name.Repo,
  database: Path.expand("../name_test.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox
```

`config/runtime.exs`:

```elixir
if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /data/name/name.db
      """

  config :name, Name.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
```

`lib/name/repo.ex`:

```elixir
defmodule Name.Repo do
  use Ecto.Repo,
    otp_app: :name,
    adapter: Ecto.Adapters.SQLite3
end
```

### Importing an existing Postgres/MySQL database

```
sequel -C postgres://localhost/database sqlite://name.db
```

Caveats stated: does not handle views, functions, triggers, or special datatypes;
Postgres arrays convert to strings and need manual JSON conversion.

### Moving the file onto the volume

```
fly sftp shell
» put ./name.db mnt/volume_name/name-prod.db
» ls /mnt
```

Download from production:

```
fly sftp get /mnt/name/name-prod.db prod.db
```

Then update `DATABASE_PATH` in `fly.toml` and:

```
fly deploy
```

### Explicitly NOT covered by this guide

Swap, `auto_stop_machines`, scaling past one Machine, snapshots/backups. Anything a critic
cites on those topics must come from the other pages below, not from this guide.

---

## 2. Elixir / Phoenix Getting Started

Sources: https://fly.io/docs/elixir/getting-started/ and https://fly.io/docs/elixir/getting-started/existing/

### Commands

```
mix archive.install hex phx_new
mix phx.new hello_elixir
cd hello_elixir
fly launch
fly secrets set MY_SECRET_KEY=my_secret_value
fly deploy
fly status
fly logs
fly apps open
fly status -a postgres-database-app-name
fly ssh issue --agent
fly ssh console --pty -C "/app/bin/hello_elixir remote"
```

### What `fly launch` does

Verbatim: `fly launch` will `"detect that we are using Phoenix, set up a Fly app, created a
Fly Postgres app and configured it for us, updated our Dockerfile, and created special
modules and scripts to run ecto migrations for us!"` It also generates
`rel/env.sh.eex` for distributed Elixir support, runs the Docker release generator, writes
`fly.toml`, and sets the secrets Phoenix requires (`SECRET_KEY_BASE`; `DATABASE_URL` when it
provisions Postgres).

### Dockerfile ENV appended by flyctl

flyctl `"attempts to modify your project's Dockerfile and append"`:

```
ENV ECTO_IPV6 true
ENV ERL_AFLAGS "-proto_dist inet6_tcp"
```

These `"enable your Elixir app to work smoothly in Fly's private IPv6 network"`; without
them you may see `nodedown` / network errors.
(Note: `ECTO_IPV6` is a Postgres-connection concern — it has no effect with ecto_sqlite3.)

### What `fly deploy` does

`"upload your application, builds a machine image, deploys the images, and then monitors to
ensure it starts successfully."`

### Not stated on these pages

`PHX_HOST`, `PORT`, `internal_port`, the literal generated `fly.toml`, and
`mix phx.gen.release --docker` are **not** shown on the Elixir getting-started pages. A
web search of fly.io confirms `fly launch` writes `[env]` entries of the form
`PHX_HOST = "your-app-name.fly.dev"` and `PORT = "8080"`, but no official page reproduces the
file — treat this as convention, not citation. `[prose only — no literal block on the page]`

---

## 3. Continuous deployment with GitHub Actions

Source: https://fly.io/docs/launch/continuous-deployment-with-github-actions/

### `.github/workflows/fly.yml`

```yaml
name: Fly Deploy
on:
  push:
    branches:
      - master    # change to main if needed
jobs:
  deploy:
    name: Deploy app
    runs-on: ubuntu-latest
    concurrency: deploy-group    # optional: ensure only one action runs at a time
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

### Token + secret setup

```
fly tokens create deploy -x 999999h
```

```
fly launch --no-deploy
```

- Store the token (including its `FlyV1` prefix) as a GitHub Actions repository secret named
  `FLY_API_TOKEN` under **Settings → Secrets and variables → Actions**.
- `fly tokens create deploy -x 999999h` produces a token scoped to a single app with a
  999999-hour expiry.
- `fly launch --no-deploy` creates the app and `fly.toml` without deploying.

---

## 4. fly.toml configuration reference

Source: https://fly.io/docs/reference/configuration/

### Top level

```toml
app = "restless-fire-6276"
primary_region = "ord"
kill_signal = "SIGTERM"
kill_timeout = 120
console_command = "/code/manage.py shell"
swap_size_mb = 512
```

- `kill_signal`: `SIGTERM`, `SIGQUIT`, `SIGUSR1`, `SIGUSR2`, `SIGKILL`, `SIGSTOP`; default `SIGINT`.
- `kill_timeout`: 1–300 seconds; default 5.
- `swap_size_mb`: megabytes; enables Linux swap on Machines.

### [build]

```toml
[build]
  builder = "paketobuildpacks/builder-jammy-base"
  buildpacks = ["docker.io/paketobuildpacks/nodejs"]
  image = "flyio/hellofly:latest"
  dockerfile = "Dockerfile.test"
  ignorefile = "/path/.dockerignore"
  build-target = "test"

[build.args]
  USER="plugh"
  MODE="production"
```

### [env]

```toml
[env]
  LOG_LEVEL = "debug"
  RAILS_ENV = "production"
  S3_BUCKET = "my-app-production"
```

Constraints: case-sensitive; names cannot begin with `FLY_`; values must be strings; secrets
take precedence over `[env]`.

### [deploy]

```toml
[deploy]
  release_command = "bin/rails db:prepare"
  release_command_timeout = "10m"
  strategy = "bluegreen"
  wait_timeout = "10m"

  [deploy.release_command_vm]
    size = "performance-1x"
    memory = "8gb"
```

```toml
[deploy]
  strategy = "rolling"
  max_unavailable = 1
```

- `strategy`: `rolling` (default), `immediate`, `canary`, `bluegreen`.
- `max_unavailable`: integer ≥1 (count) or fraction 0–1 (percentage); default `0.33`.
- `release_command_timeout` default `"5m"`.

### [http_service]

```toml
[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0
  processes = ["web"]

  [http_service.concurrency]
    type = "requests"
    soft_limit = 200
    hard_limit = 250

  [http_service.http_options]
    idle_timeout = 600

  [http_service.http_options.response]
    pristine = true

  [http_service.http_options.response.headers]
    Example-Header = false
    Example-Header-1 = "value"

  [http_service.http_options]
    h2_backend = true

  [http_service.tls_options]
    alpn = ["h2", "http/1.1"]
    versions = ["TLSv1.2", "TLSv1.3"]
    default_self_signed = false

  [[http_service.checks]]
    grace_period = "10s"
    interval = "30s"
    method = "GET"
    timeout = "5s"
    path = "/"
```

- `internal_port` default `8080`.
- `auto_stop_machines`: `"off"` (default), `"stop"`, `"suspend"`.
- `auto_start_machines` default `true`.
- `min_machines_running` default `0`.
- `concurrency.type`: `"connections"` (default) or `"requests"`; `soft_limit` default 20.

### [[services]]

```toml
[[services]]
  internal_port = 8080
  protocol = "tcp"
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0
  processes = ["web"]

  [[services.ports]]
    handlers = ["http"]
    port = 80
    force_https = true

  [[services.ports]]
    handlers = ["tls", "http"]
    port = 443

  [services.concurrency]
    type = "connections"
    hard_limit = 25
    soft_limit = 20

  [[services.tcp_checks]]
    grace_period = "1s"
    interval = "15s"
    timeout = "2s"

  [[services.http_checks]]
    interval = 10000
    grace_period = "5s"
    method = "get"
    path = "/"
    protocol = "http"
    timeout = 2000
    tls_skip_verify = false

  [[services.machine_checks]]
    image = "curlimages/curl"
    entrypoint = ["/bin/sh", "-c"]
    command = ["curl http://[$FLY_TEST_MACHINE_IP] | grep 'Hello, World!'"]
    kill_signal = "SIGKILL"
    kill_timeout = "5s"
```

### [[mounts]]

```toml
[[mounts]]
  source = "myapp_data"
  destination = "/data"
  processes = ["disk"]
  initial_size = "20gb"
  snapshot_retention = 14
  scheduled_snapshots = true
  auto_extend_size_threshold = 80
  auto_extend_size_increment = "1GB"
  auto_extend_size_limit = "5GB"
```

- `snapshot_retention`: 1–60 days; default 5.
- `scheduled_snapshots`: default `true`.
- `auto_extend_size_threshold`: percentage 0–100.
- `auto_extend_size_increment` and `auto_extend_size_limit` must be set together (GB).

Note: the reference page uses `[[mounts]]` (array of tables); the SQLite3 guide uses
`[mounts]` (single table). Both parse — see Contradictions.

### [[vm]]

```toml
[[vm]]
  size = "shared-cpu-2x"
  memory = "1gb"
  cpus = 2
  cpu_kind = "shared"
  kernel_args = "no-hlt=true"
  host_dedication_id = "customer-id"
  persist_rootfs = "never"
  processes = ["app"]
```

- `size` examples: `"shared-cpu-1x"`, `"shared-cpu-2x"`, `"performance-1x"`.
- `memory`: string with units (`"2GB"`, `"512mb"`) or integer MB (`1024`).
- `cpus`: `1`, `2`, `4`, `8`, `16`.
- `cpu_kind`: `"shared"` or `"performance"`.
- `persist_rootfs`: `"never"` (default), `"restart"`, `"always"`.

### [processes]

```toml
[processes]
  web = "bundle exec rails server -b [::] -p 8080"
  worker = "bundle exec sidekiqswarm"
```

### [checks]

```toml
[checks]
  [checks.name_of_your_http_check]
    grace_period = "30s"
    interval = "15s"
    method = "get"
    path = "/path/to/status"
    port = 5500
    timeout = "10s"
    type = "http"

    [checks.name_of_your_http_check.headers]
      Content-Type = "application/json"

  [checks.name_of_your_tcp_check]
    grace_period = "30s"
    interval = "15s"
    port = 1234
    timeout = "10s"
    type = "tcp"
```

`type` (`"http"` or `"tcp"`) and `port` are required.

### [[statics]]

```toml
[[statics]]
  guest_path = "/app/public"
  url_prefix = "/public"
  tigris_bucket = "my-bucket"
  index_document = "index.html"
```

### [metrics] and [[files]]

```toml
[metrics]
  port = 9091
  path = "/metrics"
```

```toml
[[files]]
  guest_path = "/app/config.yaml"
  local_path = "config/production.yaml"
  raw_value = "base64_encoded_content"
  secret_name = "DB_CREDENTIALS"
```

---

## 5. Volumes

### 5a. Volumes overview

Source: https://fly.io/docs/volumes/overview/

Commands referenced: `fly volumes create`, `fly volumes list`, `fly machine run`,
`fly scale count`.
Flags: `--size`, `--region`, `--snapshot-retention` (1–60 days, default 5),
`--vm-size=performance-4x`, `--require-unique-zone` (default true), `--no-encryption`.

Stated defaults / limits:

- Default volume size: **1GB**. (Conflicts with the SQLite3 guide's "3 gigabytes" — see Contradictions.)
- Maximum volume size: 500GB.
- Default snapshot retention: 5 days.
- Ephemeral disk limits: 2000 IOPs, 8MiB/s bandwidth.
- Volume IOPs/bandwidth scale with VM size (shared-cpu-1x: 4000 IOPs / 16MiB/s;
  performance-16x: 32000 IOPs / 128MiB/s).

Load-bearing statements, verbatim:

> `"A Machine can only mount one volume at a time and a volume can be attached to only one Machine."`

> `"A Fly Volume is a slice of an NVMe drive on the same physical server as the Machine on
> which it's mounted and it's tied to that hardware."`

> `"Always provision at least two volumes per app. Running an app with a single Machine and
> volume leaves you at risk for downtime and data loss."`

- Volumes do not replicate between each other; replication is the application's job.
- Volumes are **unavailable** during: image build time, and **release command execution**.
  This is the platform-level reason `release_command` cannot touch a SQLite file on a volume.

### 5b. Volume snapshots

Source: https://fly.io/docs/volumes/snapshots/

> `"We automatically take daily snapshots of all Fly Volumes"` — default retention 5 days,
> configurable 1–60.

```
fly volumes snapshots create <volume id>
```

```
fly volumes snapshots list <volume id>
```

```
fly volumes create <volume name> --snapshot-id <snapshot id> -s <volume size in GB>
```

```
fly scale count --with-new-volumes --from-snapshot <snapshot id> 1
```

```
fly volumes create <my_volume_name> --snapshot-retention <retention in days>
```

```
fly volumes update <volume id> --snapshot-retention <retention in days>
```

```
fly volumes create <my_volume_name> --scheduled-snapshots=false
```

```
fly volumes update <volume id> --scheduled-snapshots=false
```

fly.toml equivalents inside `[[mounts]]`:

```toml
snapshot_retention = 14
```

```toml
scheduled_snapshots = false
```

Snapshots are incremental; billing reflects total stored size across all snapshots.

---

## 6. Phoenix — Deploying with Releases

Source: https://hexdocs.pm/phoenix/releases.html (redirects to https://phoenix.hexdocs.pm/releases.html)
Version fetched: Phoenix v1.8.9.

### Commands

```bash
mix phx.gen.secret
export SECRET_KEY_BASE=REALLY_LONG_SECRET
export DATABASE_URL=ecto://USER:PASS@HOST/database
mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
mix phx.gen.release
MIX_ENV=prod mix release
_build/prod/rel/my_app/bin/my_app start
_build/prod/rel/my_app/bin/server
_build/prod/rel/my_app/bin/migrate
_build/prod/rel/my_app/bin/my_app remote
_build/prod/rel/my_app/bin/my_app stop
_build/prod/rel/my_app/bin/my_app eval "MyApp.Release.migrate"
mix phx.gen.release --docker
```

### Environment variables referenced

`SECRET_KEY_BASE`, `DATABASE_URL`, `MIX_ENV`, `PHX_SERVER`, `PHX_HOST`, `PORT`,
`PLATFORM_DEPLOYMENT_SHA`, `PLATFORM_DEPLOYMENT_IP`, `ECTO_IPV6`, `ERL_AFLAGS`,
`ERL_EPMD_PORT`, `RELEASE_DISTRIBUTION`, `RELEASE_NODE`, `DNS_CLUSTER_QUERY`, `NODE_IP`,
`LANG`, `LANGUAGE`, `LC_ALL`.

### `lib/my_app/release.ex`

```elixir
defmodule MyApp.Release do
  @app :my_app

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
```

### Dockerfile (from `mix phx.gen.release --docker`) — builder stage

```dockerfile
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.3
ARG DEBIAN_VERSION=trixie-20250908-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV="prod"
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile
RUN mix assets.setup
COPY priv priv
COPY lib lib
RUN mix compile
COPY assets assets
RUN mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix release
```

### Dockerfile — final stage

```dockerfile
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"
FROM ${RUNNER_IMAGE} AS final
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates && rm -rf /var/lib/apt/lists/*
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
WORKDIR "/app"
RUN chown nobody /app
ENV MIX_ENV="prod"
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/my_app ./
USER nobody
CMD ["/app/bin/server"]
```

### Clustering / VM args (only if distributed Erlang is needed)

`rel/env.sh.eex`:

```bash
export ERL_EPMD_PORT=4369
export ERL_AFLAGS="-kernel inet_dist_listen_min 4370 inet_dist_listen_max 4372"
export RELEASE_DISTRIBUTION="name"
export RELEASE_NODE="app-${PLATFORM_DEPLOYMENT_SHA}@${PLATFORM_DEPLOYMENT_IP}"
export DNS_CLUSTER_QUERY="your-app.internal"
```

`rel/vm.args.eex` (epmd-less):

```
-start_epmd false -erl_epmd_port 6789
```

`rel/remote.vm.args.eex`:

```
-start_epmd false -erl_epmd_port 6789 -dist_listen false
```

---

## 7. `fly deploy` reference

Sources: https://fly.io/docs/flyctl/deploy/ and https://fly.io/docs/launch/deploy/

Usage:

```
fly deploy [WORKING_DIRECTORY] [flags]
```

Variants shown in the deploy guide:

```
fly deploy
fly deploy -a <app-name>
fly deploy --strategy canary
```

Flags (descriptions verbatim where quoted):

- `--app string` — application name
- `--image string` — the Docker image to deploy
- `--dockerfile string` — path to a Dockerfile (defaults to working directory)
- `--config string` — path to application configuration file
- `--remote-only` — `"Perform builds on a remote builder instance instead of using the local docker daemon. This is the default."`
- `--local-only` — `"Perform builds locally using the local docker daemon."`
- `--build-only` — build but do not deploy
- `--strategy string` — `"Options are canary, rolling, bluegreen, or immediate. The default strategy is rolling."`
- `--ha` — `"Create spare machines that increases app availability (default true)"`
- `--vm-size string` — the VM size to set machines to
- `--wait-timeout string` — `"Time duration to wait for individual machines to transition states and become healthy. (default '5m0s')"`
- `--depot string` — deploy using depot to build the image (default `"auto"`)
- `--push` — push image to registry after build
- `--now` — deploy now without confirmation
- `--detach` — return immediately instead of monitoring deployment progress
- `--volume-initial-size int` — the initial size in GB for volumes created on first deploy
- `--yes` / `-y` — accept all confirmations
- Global: `-t, --access-token string`, `--debug`, `--verbose`

Deploy sequence (per the deploy guide):

1. Build — image resolution order: `--image` flag or `[build]` `image`; then the `[build]`
   method; then `--dockerfile`; then `Dockerfile`/`dockerfile` in the working directory.
2. Optional release command — `"run a one-off release command in a temporary VM...before
   that release is deployed"` (this temporary VM is why it has no volume).
3. Machine updates — apply config to existing Machines or create new ones (1–2 per process
   group on first deploy).
4. Smoke checks — Machines are watched for ~10 seconds after start; the deploy halts on
   constant non-zero exit codes.

Volume constraint: `"If a Machine has a mounted volume, `fly deploy` can't be used to mount a
different one."`

---

## 8. Autostop / Autostart

Source: https://fly.io/docs/launch/autostop-autostart/

```toml
[[services]]
  internal_port = 8080
  protocol = "tcp"
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1
```

- `auto_stop_machines`: `"off"` (or `false`), `"stop"` (or `true`), `"suspend"`. Default for
  new apps: `"stop"`.
- `auto_start_machines`: `true` / `false`. Default for new apps: `true`.
- `min_machines_running`: default `0`; **applies only to the primary region**.
- Fly Proxy uses each service's concurrency `soft_limit` to judge excess capacity; it stops at
  most one Machine per region per cycle (cycle runs every few minutes).
- Recommendation, verbatim: set `"auto_stop_machines` and `auto_start_machines` so that they
  are both enabled or both disabled"` — otherwise you get Machines that never restart, or
  Machines that never stop.
- For always-on workloads: either disable autostop entirely (`"off"` + `auto_start_machines =
  false`) or keep capacity with `min_machines_running`.

---

## 9. Blueprints

Source: https://fly.io/docs/blueprints/

**There is no blueprint for single-machine apps, SQLite, or database backups.** The closest
relevant entries:

- Resilient apps use multiple Machines — `/docs/blueprints/resilient-apps-multiple-machines/`
- Using Fly Volume forks for faster startup times — `/docs/blueprints/volume-forking/`
- Autoscale Machines — `/docs/blueprints/autoscale-machines/`
- Seamless Deployments on Fly.io — `/docs/blueprints/seamless-deployments/`
- Rollback Guide — `/docs/blueprints/rollback-guide/`
- Staging and production isolation — `/docs/blueprints/staging-prod-isolation/`
- Setting Hard and Soft Concurrency Limits — `/docs/blueprints/setting-concurrency-limits/`

### Resilient apps use multiple Machines

Source: https://fly.io/docs/blueprints/resilient-apps-multiple-machines/

- `"If your app only runs on one Machine, any of those failures means downtime."`
- `"If that host fails, the Machine goes down and does not automatically start again."`
- `"To make your app resilient to single-host failure, create at least two Machines per app or process."`
- `"You'll only get one Machine with `fly launch` for processes or apps with volumes mounted.
  Volumes don't automatically replicate your data for you."`
- `"Do not wait for a real outage to find out how your app behaves. Stop a Machine and see if traffic shifts."`

```
fly scale count 2
```

```
fly scale count 20 --region ams,ewr,gig
```

---

## 10. What Phoenix 1.8.9 + `--database sqlite3` actually ships

Not a web source — read from pristine generator output (`mix phx.new consensus --database sqlite3`
+ `mix phx.gen.auth Accounts User users` + `mix phx.gen.release --docker`, Phoenix 1.8.9 on Elixir
1.20.3 / OTP 29.0.5, captured 2026-08-07). That copy is not committed — it is ~230 MB with deps;
`.claude/skills/phoenix/SKILL.md` carries a one-liner that regenerates it.

Included because several Fly guide steps are already done for us by the modern generator, and a
critic must not flag their absence as a defect.

### `config/runtime.exs` (prod block, verbatim excerpt)

```elixir
if System.get_env("PHX_SERVER") do
  config :consensus, ConsensusWeb.Endpoint, server: true
end

config :consensus, ConsensusWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]
```

```elixir
if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/consensus/consensus.db
      """

  config :consensus, Consensus.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :consensus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :consensus, ConsensusWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
```

### `lib/consensus/application.ex` — migrations already run at boot

```elixir
    children = [
      ConsensusWeb.Telemetry,
      Consensus.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:consensus, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:consensus, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Consensus.PubSub},
      ConsensusWeb.Endpoint
    ]
```

```elixir
  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
```

### `rel/overlays/bin/server` and `rel/overlays/bin/migrate`

```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"
PHX_SERVER=true exec ./consensus start
```

```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"
exec ./consensus eval Consensus.Release.migrate
```

### `Dockerfile` (tail)

```dockerfile
WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/consensus ./

USER nobody

CMD ["/app/bin/server"]
```

`lib/consensus/release.ex` is generated identically to the Phoenix docs version (with the
`# Many platforms require SSL...` comment inside `load_app/0`).

There is **no** `fly.toml` in the generator output — it must be authored or produced by
`fly launch`.

---

## Contradictions

1. **Default volume size: 3GB vs 1GB.**
   SQLite3 guide: `"The default volume size is 3 gigabytes."`
   Volumes overview: default volume size **1GB** (max 500GB).
   → Do not rely on the default at all. Pass `--size` / `initial_size` explicitly.

2. **Mount destination: `/mnt/name` vs `/data`.**
   SQLite3 guide mounts at `/mnt/name` with `DATABASE_PATH = "/mnt/name/name.db"`.
   The fly.toml reference example uses `destination = "/data"`.
   → Either is valid; this project standardises on `/data`. The *path must match*
   `DATABASE_PATH` — that is the only real constraint.

3. **`[mounts]` vs `[[mounts]]`.**
   SQLite3 guide writes a single table `[mounts]`; the configuration reference writes an array
   of tables `[[mounts]]`. flyctl accepts both; `[[mounts]]` is the current documented form and
   is required if you ever need more than one mount.

4. **Migrations at boot: manual call vs supervision tree.**
   SQLite3 guide (older) tells you to call `Name.Release.migrate()` as the first line of
   `Application.start/2`.
   Phoenix 1.8.9's sqlite3 generator already inserts
   `{Ecto.Migrator, repos: ..., skip: skip_migrations?()}` into the supervision tree, which
   migrates on boot whenever `RELEASE_NAME` is set (i.e. in a release, i.e. on Fly).
   → Follow the generator. Adding the guide's manual `Release.migrate()` call **on top of**
   the `Ecto.Migrator` child would run migrations twice and is a defect, not a fix. Do not let
   a critic demand the literal SQLite3-guide line.

5. **`ecto_sqlite3 ~> 0.9.1`.**
   The SQLite3 guide pins an old version. Phoenix 1.8.9 generates a much newer constraint.
   → Follow the generator's `mix.exs`; the guide's version number is stale.

6. **`fly launch` provisions Postgres.**
   Both Elixir getting-started pages describe `fly launch` creating a Fly Postgres app and
   setting `DATABASE_URL`. That is wrong for this app — there must be no Postgres app and no
   `DATABASE_URL`; `DATABASE_PATH` replaces it.

7. **`ENV ECTO_IPV6 true` / `ERL_AFLAGS "-proto_dist inet6_tcp"`.**
   flyctl appends these to Phoenix Dockerfiles. `ECTO_IPV6` only affects the Postgres driver
   and is inert with ecto_sqlite3; `ERL_AFLAGS -proto_dist inet6_tcp` only matters for
   distributed Erlang, which a single machine does not use.
   → Harmless if present, unnecessary if absent. Neither presence nor absence is a defect.

8. **`--remote-only` "is the default".**
   The flyctl reference says remote building is already the default, yet the GitHub Actions
   workflow passes `--remote-only` explicitly. Keep it explicit in CI — it is documented,
   correct, and immune to a default flipping.

9. **"Always provision at least two volumes per app" vs a single-machine SQLite app.**
   The Volumes and Resilience docs insist on ≥2 Machines/volumes. A single-file SQLite
   database on one volume cannot satisfy that without LiteFS or app-level replication.
   → This is an accepted, deliberate trade-off for this project: one machine, one volume,
   snapshots as the recovery path. Documented downtime/data-loss exposure, not an oversight.

---

## Load-bearing constraints for a SQLite-on-Fly Phoenix app

Volume & database file
- Create a volume in the same region as the app: `fly volumes create <name> --size <GB> --region <primary_region>`.
- Volume names: alphanumerics and underscores only.
- Declare exactly one mount in `fly.toml`: `source` = volume name, `destination = "/data"`.
- Set `DATABASE_PATH` to a file **inside the mount** (e.g. `/data/consensus.db`) — a path
  outside the mount silently loses the DB on every deploy.
- Set `DATABASE_PATH` in `fly.toml` `[env]` (it is not a secret).
- One Machine ↔ one volume. A volume attaches to at most one Machine, and vice versa.
- Never scale past 1 Machine: `fly deploy --ha=false`, and never `fly scale count 2` — a second
  Machine gets a *different* volume and a *different*, divergent database.
- Do not enable `[[vm]] persist_rootfs` as a substitute for a volume.
- Prefer explicit sizing: `initial_size` in `[[mounts]]` or `--volume-initial-size` on deploy.
- Enable auto-extension for a DB that grows: `auto_extend_size_threshold = 80` plus both
  `auto_extend_size_increment` and `auto_extend_size_limit` (they must be set together).

Migrations
- **No `release_command` under `[deploy]`.** The release command runs in a temporary VM with no
  volume mounted; volumes are explicitly unavailable during release command execution. Any
  `release_command = "/app/bin/migrate"` in `fly.toml` is a hard defect.
- Migrations run **at application boot**. Phoenix 1.8's sqlite3 generator already does this via
  the `{Ecto.Migrator, repos: ..., skip: skip_migrations?()}` child spec, gated on
  `RELEASE_NAME` being set. Keep it; do not also call `Release.migrate()` from `start/2`.
- Keep `lib/<app>/release.ex` and `rel/overlays/bin/migrate` for manual/one-off use via
  `fly ssh console -C "/app/bin/migrate"`.
- Migrations must be idempotent-safe under repeated boots (the Machine restarts on every deploy).

Runtime environment
- `SECRET_KEY_BASE` — required, `raise`s if missing. Set as a **secret**, never in `[env]`:
  `fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)`.
- `PHX_HOST` — set in `[env]` to the public hostname (e.g. `consensus.fly.dev` or the custom
  domain). Without it the endpoint URL falls back to `example.com`, breaking absolute URLs,
  LiveView socket origin checks, and magic-link emails.
- `PORT` — must equal `internal_port` in `[http_service]`. Phoenix defaults to `4000`; Fly's
  reference default `internal_port` is `8080`. Pick one number and use it in both places.
- `PHX_SERVER=true` — required for a release to actually start the endpoint. Supplied by
  `bin/server`; the Dockerfile's `CMD ["/app/bin/server"]` is what sets it. Do not change CMD
  to `bin/<app> start` without setting `PHX_SERVER` yourself.
- Bind on all interfaces: `ip: {0, 0, 0, 0, 0, 0, 0, 0}` in `config/runtime.exs` (the generator
  already does this). Fly Proxy reaches the Machine over its private IPv6 `fly-local-6pn`
  address; a loopback-only bind (`{0,0,0,0,0,0,0,1}`) makes the app unreachable.
- `POOL_SIZE` optional; defaults to 5. SQLite is single-writer — a large pool buys nothing.
- `DATABASE_URL` must **not** be set — this app has no Postgres.
- `DNS_CLUSTER_QUERY` unnecessary on a single machine; leaving it unset is correct.
- `ECTO_IPV6` / `ERL_AFLAGS -proto_dist inet6_tcp` are Postgres/clustering concerns; inert here.

fly.toml service config
- `[http_service] internal_port` must match `PORT`.
- `force_https = true`.
- **`auto_stop_machines = "off"` and `auto_start_machines = false`, or else
  `min_machines_running = 1`.** Rationale, from the autostop docs plus the app's own nature:
  a stopped Machine drops every open LiveView WebSocket and every in-flight voting session;
  the app has in-memory state (PubSub, session timers, deadline timers) that does not survive
  a stop; cold start adds latency to the very first click on a shared link, which is exactly
  the "time to consensus" metric. Also, the two settings must be both-on or both-off — a
  Machine that stops with `auto_start_machines = false` never comes back.
- `min_machines_running` only applies in `primary_region`, so `primary_region` must be set.
- Concurrency `soft_limit` should be generous for a LiveView app: idle WebSocket connections
  count against `type = "connections"` and are what the proxy uses to judge excess capacity.
- `[[vm]]` must be explicit (`size`/`memory`), not left to platform defaults.
- `swap_size_mb` — set it (e.g. `512`) on a small `shared-cpu-1x`. The BEAM plus a Docker build
  artefact plus SQLite page cache on 256–512MB has no headroom otherwise; swap converts an OOM
  kill (which takes the whole app down, since there is only one Machine) into slowness.
- `kill_signal = "SIGTERM"` with a `kill_timeout` long enough for a clean BEAM shutdown so
  SQLite closes cleanly (WAL checkpoint) rather than being SIGKILLed mid-write.

Deploys
- `fly deploy --remote-only` (also the documented default).
- Deploy strategy on a single Machine is necessarily disruptive — `rolling` with one Machine is
  a stop-then-start. `bluegreen` is impossible with a mounted volume. Expect brief downtime per
  deploy; do not configure `bluegreen`.
- `--ha=false` (or simply never scaling) keeps it at one Machine.
- Smoke checks watch the Machine for ~10s after start; a boot-time migration failure surfaces
  there as a failed deploy — which is the desired behaviour.
- CI: `superfly/flyctl-actions/setup-flyctl@master` + `flyctl deploy --remote-only`, with
  `FLY_API_TOKEN` from `fly tokens create deploy -x 999999h` stored as a GitHub Actions secret,
  and `concurrency:` set so two deploys never race one volume.

Backups & recovery
- Daily snapshots are automatic; default retention 5 days, configurable 1–60 via
  `snapshot_retention` in `[[mounts]]` or `fly volumes update <id> --snapshot-retention <days>`.
  Raise it above the 5-day default — 5 days is short for a low-traffic app where corruption may
  go unnoticed.
- Snapshots are volume-level, not transactionally consistent with SQLite WAL. A real backup
  path is `.backup`/`VACUUM INTO` to a second file plus off-box copy, or `fly sftp get`.
- Restore path: `fly volumes create <name> --snapshot-id <id> -s <GB>`.
- Off-box copy: `fly sftp get /data/consensus.db ./prod.db`.
- Accept and document the stated risk: `"Running an app with a single Machine and volume leaves
  you at risk for downtime and data loss."`
