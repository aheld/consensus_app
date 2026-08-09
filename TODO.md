# Deploy Consensus to Fly.io — zero to auto-deploying

This is the complete runbook for taking this repository from "code on your laptop" to
"every push to `main` deploys itself." It assumes you have never used Fly.io.

Follow it top to bottom. Every command is in its own block; run them from the repository
root (`/Users/aheld/Projects/consensus_app`) unless a step says otherwise.

**How long:** about 45–75 minutes the first time. Most of it is waiting — the first
`fly deploy` builds the whole Docker image remotely (5–15 minutes), and the first CI run
compiles Elixir from scratch (3–8 minutes).

**What it costs:** Fly.io requires a payment method on file before you can deploy, even for
a small app. This configuration bills for two things running continuously: one
`shared-cpu-1x` / 512 MB Machine (`[[vm]]` in [fly.toml](fly.toml)) that never auto-stops,
and one 1 GB volume plus its daily snapshots. Check the current rates at
<https://fly.io/docs/about/pricing/> before you start — this document deliberately does not
quote dollar figures that could go stale.

**Placeholders.** Anything in `<ANGLE_BRACKETS>` is yours to fill in. Each is defined the
first time it appears, and they are collected in [Appendix A](#appendix-a--placeholder-cheat-sheet).

---

## What you are deploying

A Phoenix 1.8.9 / LiveView 1.2.8 app with SQLite. Three facts drive every decision below:

1. **The database is a single file on a Fly Volume.** `DATABASE_PATH=/data/consensus.db`
   ([fly.toml](fly.toml) `[env]`), and `/data` is where the volume mounts. A volume attaches
   to exactly one Machine, so this app runs on exactly **one** Machine, forever.
2. **There is no `[deploy] release_command`, and there must never be one.** Fly's release
   command runs in a temporary VM with no volume attached — volumes are explicitly
   unavailable during release-command execution — so it would migrate a throwaway database.
   Migrations run at application boot instead, via the `{Ecto.Migrator, ...}` child in
   [lib/consensus/application.ex](lib/consensus/application.ex). This is exactly what Fly's
   own SQLite guide prescribes: <https://fly.io/docs/elixir/advanced-guides/sqlite3/>
3. **The app seeds a bootstrap admin on first boot.** [lib/consensus/seeds.ex](lib/consensus/seeds.ex)
   creates username `aheld` with password `adminpass` unless you override it. Step 3 below
   overrides it, so that default password never exists in production.

---

## 0. Preflight

- [ ] **0.1 — Install flyctl.** On macOS with Homebrew:

```bash
brew install flyctl
```

- [ ] **0.2 — Or use the official installer** if you don't have Homebrew (works on macOS and
      Linux; it prints the `PATH` line you need to add to your shell profile):

```bash
curl -L https://fly.io/install.sh | sh
```

- [ ] **0.3 — Confirm flyctl is on your PATH.** Both `fly` and `flyctl` are the same binary;
      this document uses `fly`.

```bash
fly version
```

- [ ] **0.4 — Create a Fly.io account** (skip to 0.5 if you already have one). This opens a
      browser:

```bash
fly auth signup
```

  **You will be asked for a payment method.** Fly requires a card on file before it will run
  a Machine, including on the smallest sizes. Add it now — the first deploy will fail
  otherwise, in a way whose error message is not obvious.

- [ ] **0.5 — Or log in to an existing account:**

```bash
fly auth login
```

- [ ] **0.6 — Verify you are logged in.** This prints the email address of the account
      everything below will be billed to:

```bash
fly auth whoami
```

- [ ] **0.7 — Confirm the GitHub CLI is installed:**

```bash
gh --version
```

  If it is missing: `brew install gh`.

- [ ] **0.8 — Confirm the GitHub CLI is authenticated, then read two lines of its output —
      the protocol line first.** Which credential your `git push` uses decides whether the
      scope half of this step applies to you at all:

```bash
gh auth status
```

  If it reports you are not logged in, run `gh auth login` first and pick HTTPS or SSH to
  match how you normally push. Then:

  **First, `Git operations protocol:`.** This is the one that tells you what to do next:

  - **`ssh`** — your pushes are authenticated by your SSH key, and SSH carries no OAuth
    scopes, so nothing below can reject them. You still need **`repo`** in `Token scopes:`
    for `gh secret set` in §5.2, but you can skip the `workflow` scope entirely and go to
    §0.9. (If you would rather not depend on that, adding the scope anyway is harmless.)
  - **`https`** — this is `gh`'s default, and it routes the push through exactly the OAuth
    token below. Keep reading; the `workflow` scope is load-bearing for you.

  **Then, over HTTPS, `Token scopes:`.** It must list **`repo`** *and* **`workflow`**:

  - `repo` is what lets `gh secret set` write an Actions secret in §5.2. You need this on
    either protocol.
  - `workflow` is what lets the **first push** in §1.6/§1.7 succeed. `.github/` has never been
    committed in this repository (`git ls-files` proves it), so that push is the one that
    *creates* `.github/workflows/ci.yml` and `.github/workflows/fly-deploy.yml` — and GitHub
    refuses any push that creates or updates a workflow file when the credential is an OAuth
    token without `workflow`. `gh`'s documented minimum scopes are `repo`, `read:org` and
    `gist`, so a stock `gh auth login` does **not** give you `workflow`.

  If `workflow` is missing, add it. `gh auth refresh` keeps the scopes you already have and
  adds this one:

```bash
gh auth refresh -s workflow
```

  Then re-run `gh auth status` and confirm `workflow` now appears in `Token scopes:` before
  going any further. On a fresh login you can ask for it up front instead, with
  `gh auth login --scopes workflow`.

  Switching protocol is also a valid fix in either direction: `git remote set-url origin
  git@github.com:<GITHUB_USER>/<REPO_NAME>.git` moves the push onto SSH and out of the
  scope check. §8 has a row for the rejection if you meet it anyway.

- [ ] **0.9 — Confirm Elixir is available**, so you can generate a secret in step 3. On this
      machine Elixir lives in `/opt/homebrew/bin`:

```bash
mix --version
```

  `mix phx.gen.secret` in §3.1 is a task that ships with the `phoenix` dependency, so it only
  exists once this checkout's deps are fetched. If you have never run `mix setup` (or at least
  `mix deps.get`) here, do it now — otherwise §3.1 fails with a "could not be found" error
  that looks like a broken Elixir install and is not. If you would rather not fetch deps at
  all, this produces an equivalent 64-character secret with no dependencies:

```bash
elixir -e ':crypto.strong_rand_bytes(48) |> Base.encode64() |> IO.puts()'
```

---

## 1. Push this repository to GitHub

Continuous deployment (step 5) is a GitHub Actions workflow, so the code has to live on
GitHub first.

> **If the working tree is already clean, steps 1.1 and 1.3–1.5 are already done.** The application
> was committed and tagged (`git tag --list` shows a `v0.1.0-foundation` tag) at the end of the build
> that produced it. `git log --oneline` will show those commits. In that case read 1.1–1.5 for
> context, confirm 1.2 (you are on `main`), and start doing at 1.6. Everything below still applies
> verbatim if you have since made changes of your own.

- [ ] **1.1 — See what is currently tracked versus untracked.** If nothing has been committed yet,
      almost the entire application is untracked — only `docs/`, `CLAUDE.md`, `README.md`,
      `.gitignore` and `.claude/settings.json` have ever been committed:

```bash
git status
```

- [ ] **1.2 — Confirm your branch is `main`.**
      [.github/workflows/fly-deploy.yml](.github/workflows/fly-deploy.yml) triggers on
      `push: branches: [main]`. On any other branch name, nothing deploys and you get no
      error to tell you why:

```bash
git branch --show-current
```

  If it prints something else, rename it: `git branch -M main`.

- [ ] **1.3 — Stage everything:**

```bash
git add -A
```

- [ ] **1.4 — Review exactly what you are about to commit.** Read this list. It is the last
      cheap moment to catch a secret:

```bash
git status --short
```

  Three things to check specifically:

  - **`fly.toml` MUST appear in the list.** Fly's continuous-deployment guide calls this out
    explicitly — the GitHub Actions runner has no local config, so it reads `fly.toml` out of
    the checkout to know the app name, the mount, and the env vars.
    <https://fly.io/docs/launch/continuous-deployment-with-github-actions/>
  - **No `.env` files and no `*.db` files should appear.** [.gitignore](.gitignore) covers
    `.env`, `.env.*` (except `.env.example`), `*.db` and `*.db-*`, plus `/_build/`, `/deps/`
    and `erl_crash.dump`. If you see one of those staged anyway, unstage it before committing.
  - **A handful of already-tracked files show as modified** — `README.md`, `CLAUDE.md`,
    `.gitignore` and files under `docs/`. That is expected: they were updated alongside the
    application code (the README now documents setup and the bootstrap-password warning; the
    `.gitignore` gained the `*.db` and `.env` rules the bullet above relies on). Skim
    `git diff --cached` if you want, but keep them — nothing here needs restoring.

- [ ] **1.5 — Commit:**

```bash
git commit -m "Add Phoenix application, Docker release, CI and Fly.io deploy config"
```

- [ ] **1.6 — Create the GitHub repository and push, interactively.** `gh` walks you through
      name, visibility, and remote:

```bash
gh repo create
```

  Choose **"Push an existing local repository to GitHub"**, accept `.` as the path, pick a
  name, choose Private (recommended for now), and answer yes to adding a remote named
  `origin` and pushing.

- [ ] **1.7 — Or do it in one line.** `<GITHUB_USER>` is your GitHub username or organisation;
      `<REPO_NAME>` is what you want the repository called (e.g. `consensus`):

```bash
gh repo create <GITHUB_USER>/<REPO_NAME> --private --source=. --remote=origin --push
```

  **If the push is rejected** with `refusing to allow an OAuth App to create or update
  workflow ... without workflow scope`, your token is missing the `workflow` scope from §0.8.
  The repository was still created and `origin` was still added — fix the scope with
  `gh auth refresh -s workflow` and then push with `git push -u origin main`. Do **not** re-run
  `gh repo create`. See the matching row in §8.

- [ ] **1.8 — Confirm the push actually landed**, then look at it. Everything from here on
      assumes the code is on GitHub; the first command must report `## main...origin/main`
      with nothing ahead, and the second must list `.github/workflows/fly-deploy.yml`:

```bash
git status -sb
```

```bash
git ls-tree -r --name-only origin/main -- .github
```

```bash
gh repo view --web
```

- [ ] **1.9 — Expect one red X, and ignore it.** That push to `main` just triggered
      [.github/workflows/fly-deploy.yml](.github/workflows/fly-deploy.yml). Its `test` job
      (which reuses [.github/workflows/ci.yml](.github/workflows/ci.yml)) should pass; its
      `deploy` job will **fail**, because `FLY_API_TOKEN` does not exist yet and the Fly app
      does not exist yet. Step 5 fixes this. Nothing is broken.

---

## 2. Create the Fly app and its volume

- [ ] **2.1 — Pick a region.** The Machine and the volume must live in the same region, and
      because there is only one of each, that choice is permanent-ish. Pick the one closest
      to your users. This lists every region with its three-letter code:

```bash
fly platform regions
```

  Note the code you want as `<REGION>` — e.g. `iad` (Ashburn, Virginia), `ord` (Chicago),
  `lhr` (London), `syd` (Sydney).

- [ ] **2.2 — Choose an app name.** `<FLY_APP_NAME>` must be **globally unique across all of
      Fly.io**, may contain lowercase letters, digits and hyphens, and becomes your hostname:
      `<FLY_APP_NAME>.fly.dev`. `consensus-app` is almost certainly taken — pick something
      like `consensus-<yourname>`.

- [ ] **2.3 — Edit [fly.toml](fly.toml).** Change exactly three values, and make sure
      `PHX_HOST` matches the app name:

  | Line | Current | Change to |
  |---|---|---|
  | `app` | `'consensus-app'` | `'<FLY_APP_NAME>'` |
  | `primary_region` | `'iad'` | `'<REGION>'` |
  | `[env] PHX_HOST` | `'consensus-app.fly.dev'` | `'<FLY_APP_NAME>.fly.dev'` |

  Leave everything else alone. In particular do **not** change `PORT`/`internal_port` (they
  must stay equal), `DATABASE_PATH` (it must stay inside the `[[mounts]]` destination), or
  the `auto_stop_machines` / `auto_start_machines` / `min_machines_running` trio.

  **The `app` / `PHX_HOST` pair has a test guarding it — run it now, before you deploy.**
  [test/consensus/deploy_config_test.exs](test/consensus/deploy_config_test.exs) reads
  `fly.toml` and asserts that `PHX_HOST` is exactly `<app>.fly.dev`, that `PORT` equals
  `internal_port`, and that `DATABASE_PATH` sits under `[[mounts]] destination`. It needs no
  database and runs in milliseconds:

```bash
mix test test/consensus/deploy_config_test.exs
```

  This exists because changing `app` and forgetting `PHX_HOST` fails *silently and only in
  production*: `check_origin` defaults to true, so every LiveView socket upgrade 403s, while
  `GET /` still answers 200 (LiveView static-renders before any socket exists) and `/health`
  still answers 200 (it is origin-free and outside the `:browser` pipeline) — so Fly reports
  the Machine healthy and the deploy goes green over a completely non-interactive app. The
  Docker smoke test in CI cannot catch it either: that step reads `PHX_HOST` out of `fly.toml`
  and feeds the same value to the container, so the two drifting apart is invisible to it.

  **If you are deliberately serving this app from a custom domain** rather than
  `<app>.fly.dev`, `PHX_HOST` must be that domain and this test will fail. That is a real
  decision, not a broken test: record it in [docs/decisions.md](docs/decisions.md) and **edit
  the assertion to match your domain — do not delete the test.** Deleting it removes the only
  guard on the failure mode described above, and you will meet that failure mode again the
  next time you rename the app.

- [ ] **2.4 — Commit that edit and push it.** Easy to skip, expensive to miss: the GitHub
      Actions workflow you set up in §5 deploys the `fly.toml` **that is in the repository**,
      not the one on your laptop. Leave this uncommitted and every automated deploy targets
      `consensus-app` — an app you do not own — while `fly deploy` from your laptop keeps
      working, which makes it look like CI is broken for some other reason.

```bash
git commit -am "Point fly.toml at <FLY_APP_NAME> in <REGION>"
```

```bash
git push
```

  This push triggers another `Fly Deploy` run, which will fail at the `deploy` job for the same
  reason as §1.9 — no `FLY_API_TOKEN`, no Fly app yet. Still expected; still ignore it.

- [ ] **2.5 — Create the app.** This registers the name and nothing else — no Machine, no
      volume, no deploy:

```bash
fly apps create <FLY_APP_NAME>
```

  **Why not `fly launch`?** Because `fly launch` detects Phoenix and offers to provision a
  Fly Postgres app and set `DATABASE_URL`, which is wrong for this app — it uses SQLite on a
  volume via `DATABASE_PATH`, and a stray `DATABASE_URL` is pure confusion. `fly launch` also
  rewrites `fly.toml`, discarding the tuned configuration already in this repo. If you prefer
  the guided flow anyway, `fly launch --no-deploy` is the variant the CD guide names — but
  then re-check every value in §2.3 afterwards, and re-do §2.4 — `fly launch` rewrites
  `fly.toml` in your working tree, not in the repository.

- [ ] **2.6 — Create the volume.** The name **must be `consensus_data`**, because that is the
      `source` in the `[[mounts]]` block of [fly.toml](fly.toml). A mismatch means the deploy
      creates a *different* empty volume, or fails outright. (Fly volume names allow only
      alphanumerics and underscores — no hyphens — which is why it is not `consensus-data`.)

```bash
fly volumes create consensus_data --region <REGION> --size 1 --snapshot-retention 30 --app <FLY_APP_NAME>
```

  flyctl will warn you that a single volume is pinned to a single physical host and that Fly
  recommends two or more per app, then ask you to confirm. Answer **yes**. This is a
  deliberate, documented trade-off for a single-file SQLite app: one Machine, one volume,
  snapshots as the recovery path. Fly states the exposure plainly — *"Running an app with a
  single Machine and volume leaves you at risk for downtime and data loss."*
  (<https://fly.io/docs/volumes/overview/>)

  `--size 1` is 1 GB, matching `initial_size = '1gb'` in `[[mounts]]`. The volume auto-extends
  from there: `auto_extend_size_threshold = 80`, `+1gb` at a time, up to `10gb`.

  **`--snapshot-retention 30` is not optional here, even though `[[mounts]]` in
  [fly.toml](fly.toml) already says `snapshot_retention = 30`.** `fly volumes create --help`
  documents `--snapshot-retention int  Snapshot retention in days (default 5)`, and this
  volume is being created *by hand, before any Machine exists* — the `[[mounts]]` value is
  what Fly applies to a volume it creates for you during a deploy, so it does not reach back
  and re-configure a volume you made yourself. Leave the flag off and you get Fly's 5-day
  default while `fly.toml` claims 30, which is the worst of both: the file you would read in
  an emergency is wrong about how far back you can go. Retention is 1–60 days; 30 is chosen
  because silent corruption on a low-traffic app can easily go unnoticed over a long weekend.

- [ ] **2.7 — Confirm it exists, is in the right region, and kept the retention you asked
      for.** `fly volumes list` gives you the region and the `vol_...` identifier — that is
      `<VOLUME_ID>`, and you will need it again in §7. `fly volumes show` is what actually
      prints the retention, and it is worth one command now rather than a discovery during a
      restore:

```bash
fly volumes list --app <FLY_APP_NAME>
```

```bash
fly volumes show <VOLUME_ID> --app <FLY_APP_NAME>
```

  If retention reads 5, fix it in place — no redeploy, no downtime:

```bash
fly volumes update <VOLUME_ID> --snapshot-retention 30 --app <FLY_APP_NAME>
```

---

## 3. Set secrets — before the first deploy

Fly secrets are encrypted values injected as environment variables into the **running
Machine**. They are **not** available during the Docker build. That is fine here:
[config/runtime.exs](config/runtime.exs) reads `SECRET_KEY_BASE` and `DATABASE_PATH` at boot,
not at compile time. Never put a secret in `fly.toml` `[env]` — that file is committed to
GitHub. (Secrets also take precedence over `[env]` if a name appears in both.)

- [ ] **3.1 — Generate a secret key base.** Phoenix uses it to sign and encrypt cookies. It
      prints 64 characters:

```bash
mix phx.gen.secret
```

- [ ] **3.2 — Set it.** `<SECRET_KEY_BASE>` is the string you just generated. If it is
      missing, the app **refuses to boot** — `config/runtime.exs` raises
      `environment variable SECRET_KEY_BASE is missing.`:

```bash
fly secrets set SECRET_KEY_BASE=<SECRET_KEY_BASE> --app <FLY_APP_NAME>
```

- [ ] **3.3 — Set the bootstrap admin credentials. Strongly recommended, and it must happen
      now.** [lib/consensus/seeds.ex](lib/consensus/seeds.ex) creates a bootstrap admin only
      on a boot where the database holds **no administrator at all**
      (`Accounts.count_admins() == 0`), and it never modifies an existing user — once any
      admin exists, `Consensus.Seeds.run!/0` returns `admin: nil` and touches nothing. So if
      you let the defaults through once, the account is created with password `adminpass` and
      setting `ADMIN_PASSWORD` afterwards does nothing. Set it before the first deploy and
      the default never exists in production at all.

  `<STRONG_ADMIN_PASSWORD>` must be **at least 12 characters** — that is
  `Consensus.Accounts.User.min_password_length/0`. Seeding waives the minimum for the
  built-in `adminpass` string and for nothing else, so an `ADMIN_PASSWORD` shorter than 12
  characters is *rejected*: on a genuine first boot (no users at all) `Consensus.Seeds`
  raises `could not seed the bootstrap admin user` and the deploy fails, which is the
  intended outcome. `<YOUR_EMAIL>` is a real address you control.

```bash
fly secrets set ADMIN_PASSWORD='<STRONG_ADMIN_PASSWORD>' ADMIN_EMAIL='<YOUR_EMAIL>' --app <FLY_APP_NAME>
```

  Use single quotes so your shell does not eat `$`, `!` or spaces. `ADMIN_USERNAME` is also
  supported (default `aheld`) if you want a different login name.

- [ ] **3.4 — Confirm the names are stored** (values are never shown — you only see a digest
      and a timestamp):

```bash
fly secrets list --app <FLY_APP_NAME>
```

  You should see `SECRET_KEY_BASE`, and `ADMIN_PASSWORD` / `ADMIN_EMAIL` if you set them.
  There is no Machine yet, so nothing restarts. Later, changing a secret restarts the running
  Machine so it picks up the new value — on a single-Machine app that is a few seconds of
  downtime.

---

## 4. First deploy

- [ ] **4.1 — Deploy.** `--ha=false` is what keeps this at **one** Machine; without it Fly
      creates a spare, and a spare Machine cannot mount this volume:

```bash
fly deploy --ha=false --app <FLY_APP_NAME>
```

  What Fly does, in order: uploads the build context, builds the image from
  [Dockerfile](Dockerfile) on a remote builder (remote building is flyctl's default), creates
  the Machine with `consensus_data` mounted at `/data`, starts it, then watches it for about
  ten seconds. A crash during that window fails the deploy — which is what you want, because
  migrations run at boot and a broken migration should stop the release.

  Watch for, in the output:

  - A build section that ends in a success line. The first build is slow; later ones reuse
    layers.
  - **No line about creating a volume.** You created it in step 2.6. If flyctl says it is
    creating one, the `source` in `fly.toml` and the volume you created do not match — stop
    and fix that before you end up with two volumes.
  - A machine-state section ending with the machine `started`, and a count of **1**.
  - **A health check going green.** `fly.toml` declares one `[[http_service.checks]]` — a
    `GET /health` every 30s with a 5s timeout, after a 15s `grace_period` that covers
    boot-time migrations and seeding. It deliberately does **not** point at `/`: Fly's checker
    connects over plain HTTP to the machine's private address, and `force_ssl` in
    `config/prod.exs` would 301-redirect `/`, so a check on `/` could never pass. `/health` is
    on that `force_ssl` exclusion list, and `ConsensusWeb.HealthController` proves two things
    before answering `200 ok`: that `Ecto.Migrator.migrations/3` reports **no `:down`
    migrations**, and that `SELECT 1 FROM users LIMIT 1` succeeds. A bare `SELECT 1` would
    prove neither — it is a constant expression SQLite answers without touching a table, so a
    database file with no schema at all passes it, and a release whose boot-time migrator never
    ran would report 200 here while `GET /` returned 500. Instead you get `503 migrations
    pending` for an un-migrated database and `503 database unavailable` for one whose volume
    has gone away. flyctl waits for the check before reporting the deploy successful —
    `fly deploy --help` describes
    `--wait-timeout` (default `5m0s`) as the time to wait for machines "to transition states
    and become healthy". The ~10s smoke window watches for a *crash*; the health check is what
    keeps watching afterwards, for the life of the machine.
  - **No mention of a release command.** There is deliberately none.

  If the deploy hangs or fails at the "monitoring" stage, the app crashed on boot. Go
  straight to step 4.2 — the reason will be in the logs.

- [ ] **4.2 — Read the boot logs.** This is where you confirm the two things that only happen
      at boot — migrations and seeding:

```bash
fly logs --app <FLY_APP_NAME>
```

  You are looking for, roughly in this order:

  - **Two lines of harmless noise at the very top, before anything below.** Neither is a
    problem and neither needs action; they are listed here only so you do not spend your
    first ten minutes on Fly chasing them.

    ```
    =ESOCK WARNING MSG==== 08-Aug-2026::15:24:59.330477 ===
    [UNIX-ESSIO] Failed open sctp dynamic library: libsctp.so.1
    ```

    The Debian-slim runtime image has no SCTP library. Nothing in this app uses SCTP; the
    BEAM says so once at startup and moves on. It prints on **every** boot.

    ```
    15:25:00.064 [error] Exqlite.Connection (#PID<0.1941.0> ("db_conn_4")) failed to connect: ** (Exqlite.Error) database is locked
    15:25:00.064 [error] Exqlite.Connection (#PID<0.1941.0> ("db_conn_3")) failed to connect: ** (Exqlite.Error) database is locked
    ```

    **This should no longer happen at all, as of D-038 — see the note below.** It is kept
    because the reasoning still explains the shape of any `database is locked` you meet at
    boot, and because a raised `POOL_SIZE` brings it straight back.

    > **D-038 note.** `pool_size` is now **1** by default, so there is exactly one connection
    > opening and nothing for it to race. The two lines below were an artefact of the old
    > `pool_size: 5`. If you see them on a fresh volume today, the first thing to check is
    > whether `POOL_SIZE` has been set to something greater than 1 as a Fly secret or in
    > `fly.toml`.

    **Red `[error]`, and was expected — but only on the first boot against an empty volume.**
    Usually two lines, sometimes one — across three fresh volumes this printed 2, 1 and 2. It
    is a race, so both the count and *which* `db_conn_N` loses vary between otherwise
    identical boots, and in principle a boot where none of them collide prints none at all.
    Treat one or two as normal and zero as equally fine. The pool's connections
    (five of them, back when `config/runtime.exs` defaulted `pool_size` to 5) open
    simultaneously and
    each runs `PRAGMA journal_mode = wal` as part of connecting. On a **brand-new** database
    file that pragma has to convert the file's journal mode, which takes an exclusive lock —
    and in `Exqlite.Connection.do_connect/2` the journal-mode pragma is applied eleven steps
    *before* the busy timeout is, so the connections that lose the race get SQLite's
    zero-wait `SQLITE_BUSY` instead of waiting out the `busy_timeout: 5_000` that
    `config/runtime.exs` sets. `DBConnection` reconnects immediately and the boot continues —
    which is why the migration lines below still appear, milliseconds later.

    Once the file exists, `journal_mode = wal` is already in effect, the pragma is a no-op
    that takes no lock, and there is nothing to contend for. **So this line must never appear
    on a second boot.** If you see it on a machine that has been up before, it is not this
    race — go to §8's "on an established database" row, which is a genuinely different
    problem.

  - `== Running 20260808033720 Consensus.Repo.Migrations.CreateUsersAuthTables.change/0 forward`
    and three more `== Running ...` lines the same shape, one per migration in
    `priv/repo/migrations/` — currently `CreateHomePage`, `CreateActivityGroups` and
    `DropHomePage`, in that timestamp order. (Yes, a fresh boot creates the `home_page` table
    and then drops it a migration later — that is the history of the app, not a mistake; see
    [docs/decisions.md](docs/decisions.md) D-027.) This is the `{Ecto.Migrator, ...}`
    supervision-tree child doing its job. On a second boot you get `Migrations already up`
    instead. Run `ls priv/repo/migrations/*.exs` if you want the exact current count and names —
    this list grows every time a migration is added and this document is not the place that
    tracks that.
  - `[seeds] created bootstrap admin "aheld"` (or your `ADMIN_USERNAME`) — from
    `Consensus.Seeds.run!/0`. Only on the first boot; afterwards an admin already exists and
    `Consensus.Seeds` no-ops silently.
  - **If you skipped step 3.3**, also a loud warning: `[seeds] the admin account "aheld" is
    using the default password "adminpass". Anyone who can reach this app can take it over.`
    Unlike the two above, this one repeats on **every** boot until you change the password.
  - `Running ConsensusWeb.Endpoint with Bandit ... at :::8080 (http)`.

  Press Ctrl-C to stop tailing.

  So a clean **first** boot reads: SCTP warning, zero-to-two `database is locked` errors, one
  `== Running ...` line per migration (see above), `[seeds] created bootstrap admin`, the
  default-password warning if you skipped §3.3, then Bandit. A clean **second** boot reads: SCTP warning, `Migrations already
  up`, the default-password warning if it still applies, then Bandit — no lock errors and no
  seed line. Both sequences were reproduced against this repository's release image, on empty
  volumes and on reused ones.

- [ ] **4.3 — Check the Machine:**

```bash
fly status --app <FLY_APP_NAME>
```

  Expect exactly one Machine in state `started`, in `<REGION>`, and its health check
  reported as passing. `fly checks list --app <FLY_APP_NAME>` shows the `GET /health` check on
  its own if you want it unambiguously.

- [ ] **4.4 — Open the app.** (`fly open` still works but prints
      *"Command "open" is deprecated, use `fly apps open` instead"*.)

```bash
fly apps open --app <FLY_APP_NAME>
```

  You should get the Consensus splash screen at `https://<FLY_APP_NAME>.fly.dev/` — signed
  out, so **Get started** and "Have a link? Open it →". There is no admin-editable message on
  this page any more; see [docs/decisions.md](docs/decisions.md) D-027.

- [ ] **4.5 — Log in.** Go to `https://<FLY_APP_NAME>.fly.dev/users/log-in`. Use the
      **"Email or username"** field — it accepts either. Enter your `ADMIN_USERNAME`
      (default `aheld`) and the password you set in step 3.3 (or `adminpass` if you skipped
      it). Use the password form, not the magic-link form, **unless you have already set
      `RESEND_API_KEY`**. Resend is the configured provider (D-039), but
      [config/runtime.exs](config/runtime.exs) only selects it when that secret exists; without
      it the fallback is
      `config :consensus, Consensus.Mailer, adapter: Swoosh.Adapters.Logger, level: :info`,
      so a send succeeds and `fly logs` shows `New email delivered to <address>`, but the body
      — and therefore the link — is never logged and never reaches an inbox. Check with
      `fly secrets list`. Note that a key alone is not enough: `MAIL_FROM` must be on a domain
      verified in the Resend dashboard, or every send is rejected at the provider.
      (See [docs/decisions.md](docs/decisions.md) D-014, partly superseded by D-039: the
      generated `Swoosh.Adapters.Local` plus `config :swoosh, local: false` combination made
      every delivery *exit* in a release, which is why the fallback is `Logger`.)

- [ ] **4.6 — Change the password if you skipped step 3.3.** Go to
      `https://<FLY_APP_NAME>.fly.dev/users/settings` and use the "New password" form. The
      minimum is **12 characters**. That page requires "sudo mode" — the gate is the
      `:require_sudo_mode` `on_mount` hook in
      [lib/consensus_web/user_auth.ex](lib/consensus_web/user_auth.ex), which calls
      `Accounts.sudo_mode?(user, -10)`, so the authentication must be within the last
      **10 minutes** — do it right after logging in or it will bounce you back to the
      login form.

- [ ] **4.7 — Confirm the warning banner is gone.** Visit
      `https://<FLY_APP_NAME>.fly.dev/admin/users`. If you set `ADMIN_PASSWORD` in step 3.3
      there was never a banner. If you just changed the password, **reload the page** — the
      banner state is computed when the LiveView mounts, so a stale tab keeps showing it.
      While you are there, confirm the table lists your admin account with role `admin`.

---

## 5. Continuous deployment

[.github/workflows/fly-deploy.yml](.github/workflows/fly-deploy.yml) already exists. On every
push to `main` (and on manual `workflow_dispatch`) it:

1. Runs the `test` job by calling [.github/workflows/ci.yml](.github/workflows/ci.yml), which is
   itself two jobs. `test`, on Elixir 1.20.3 / OTP 29.0.5 with `MIX_ENV=test`:
   `mix deps.get --check-locked`, `mix deps.unlock --check-unused`,
   `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. `docker`, in
   parallel: it builds the release image from [Dockerfile](Dockerfile) **and then runs it** —
   booting the container against a tmpfs `/data` owned by uid 65534 (which is how Fly presents
   an *empty* volume to a release running as `nobody`), polling `/health` until it answers
   `200 ok`, completing a real LiveView websocket handshake and asserting `101` under the
   `PHX_HOST` it reads out of `fly.toml`, asserting `count_admins() == 1` over
   `/app/bin/consensus rpc`, breaking the schema and asserting `/health` then answers `503`,
   and finally booting **twice on one volume** so a migration runs against a populated
   database. That is the only thing anywhere in this repository that exercises the boot-time
   `{Ecto.Migrator, ...}` child, `Consensus.Seeds`, `Consensus.BootCheck.run!/0` and the
   `config_env() == :prod` half of `config/runtime.exs` — `mix test` never starts a release. A
   build-only job is what let a `/health` regression deploy green once already; do not reduce
   it back to one. Both jobs must go green. Note that `ci.yml` triggers only on
   `pull_request` and `workflow_call` —
   deliberately **not** on `push` to `main`, because this workflow already calls it, and a push
   trigger would run the whole matrix and the Docker build a second time for every merge.
2. Only if that passes (`needs: test`), runs `flyctl deploy --remote-only --ha=false`.
3. Serialises deploys with `concurrency: {group: deploy-group, cancel-in-progress: false}`, so
   two deploys can never fight over the one volume; a second push queues rather than being
   dropped.
4. Runs with `permissions: contents: read` — nothing in either workflow writes to the
   repository, so the job's `GITHUB_TOKEN` gets no more than it needs.

All it is missing is the token. This is straight out of
<https://fly.io/docs/launch/continuous-deployment-with-github-actions/>.

- [ ] **5.1 — Create a deploy token** scoped to this one app, with a very long expiry
      (999999 hours ≈ 114 years):

```bash
fly tokens create deploy -x 999999h --app <FLY_APP_NAME>
```

  **Copy the entire output, including the leading `FlyV1 ` — space and all.** It is one long
  string that begins `FlyV1 fm2_...`. Dropping the prefix is the single most common mistake
  here, and it produces an authentication failure that looks like a permissions problem. Call
  the whole thing `<FLY_DEPLOY_TOKEN>`.

- [ ] **5.2 — Store it as a GitHub Actions secret, without putting it in your shell history.**
      This prompts you to paste, then reads from stdin. Run it from the repository root — `gh`
      infers the repository from the `origin` remote; from anywhere else, add
      `-R <GITHUB_USER>/<REPO_NAME>`:

```bash
gh secret set FLY_API_TOKEN --app actions
```

- [ ] **5.3 — Or pass it inline.** The double quotes are required, because the token contains
      a space:

```bash
gh secret set FLY_API_TOKEN --app actions --body "<FLY_DEPLOY_TOKEN>"
```

- [ ] **5.4 — Or use the web UI.** In your repository: **Settings → Secrets and variables →
      Actions → New repository secret**. Name it exactly `FLY_API_TOKEN`, paste the whole
      token (including `FlyV1 `) into Secret, and click **Add secret**.

- [ ] **5.5 — Confirm it is registered** (you will never see the value again — that is
      correct):

```bash
gh secret list
```

- [ ] **5.6 — Check that the repository's `fly.toml` is the one you edited.** This is the
      single most common way this step fails. `git status` must not list `fly.toml`, and the
      committed copy must name your app:

```bash
git status --short fly.toml
```

```bash
git show HEAD:fly.toml | grep -E "^app|PHX_HOST"
```

  If either shows `consensus-app`, go back and finish §2.4 before continuing — CI would
  deploy to an app you do not own.

- [ ] **5.7 — Trigger a deploy.** Any commit to `main` will do; an empty one is enough now
      that §5.6 has confirmed the config is already pushed:

```bash
git commit --allow-empty -m "Trigger first automated deploy"
```

```bash
git push
```

- [ ] **5.8 — Watch it run:**

```bash
gh run watch
```

  The `test` job runs first; `deploy` starts only after it goes green. Total time is usually
  5–12 minutes on a cold cache.

- [ ] **5.9 — If it failed, read the log for the failing job:**

```bash
gh run view --log-failed
```

---

## 6. Verify the whole thing

Substitute your app name. Everything here should hold before you call this done.

- [ ] `https://<FLY_APP_NAME>.fly.dev/` → the home page loads over HTTPS, showing the editable
      message. (Plain `http://` redirects to `https://` — `force_https = true` in `fly.toml`
      plus `force_ssl` in `config/prod.exs`.)
- [ ] `https://<FLY_APP_NAME>.fly.dev/health` → `200` with the body `ok`. This is the endpoint
      Fly's checker polls, and it answers only after `Ecto.Migrator.migrations/3` reports no
      `:down` migrations **and** `SELECT 1 FROM users LIMIT 1` succeeds against the database on
      the volume. The failure bodies are `migrations pending` and `database unavailable`, both
      with status `503`.
- [ ] `https://<FLY_APP_NAME>.fly.dev/admin/users` **while signed out** → redirects to
      `/users/log-in`.
- [ ] `https://<FLY_APP_NAME>.fly.dev/users/log-in` with your admin username + password →
      lands back on `/`, signed in.
- [ ] `https://<FLY_APP_NAME>.fly.dev/admin/users` **while signed in as admin** → 200, lists
      your account, **no default-password banner**.
- [ ] `https://<FLY_APP_NAME>.fly.dev/groups/new` → build a group (a title, one deadline chip),
      add one option on the next screen, then open `/groups/<id>/options` **in a second browser
      tab signed in as the same admin account** and add a second option in the *first* tab.
      Watch it appear in the second tab **without refreshing**. That proves the LiveView
      WebSocket and PubSub are both working, which in turn proves `PHX_HOST` is correct. (There
      is no admin-editable home-page message to use for this any more — D-027 — so the creation
      flow is what exercises real-time updates on a fresh deploy. Leave the group as a draft;
      the durability test below builds its own.)
- [ ] `https://<FLY_APP_NAME>.fly.dev/admin/dashboard` → Phoenix LiveDashboard, admin-only in
      every environment.
- [ ] `https://<FLY_APP_NAME>.fly.dev/users/register` → create a throwaway account; you should
      be signed in immediately with "Account created successfully!". Keep its username and
      password — the promotion test below uses it.
- [ ] `fly status --app <FLY_APP_NAME>` → exactly **one** Machine, `started`.
- [ ] `fly volumes list --app <FLY_APP_NAME>` → exactly **one** volume named `consensus_data`,
      attached to that Machine.
- [ ] The most recent GitHub Actions run is green:

```bash
gh run list --workflow="Fly Deploy"
```

**Stop there on purpose.** The creation-flow check above gets you to a working share link
(`/groups/:id/share`); there is nothing on the other end of it yet. The recipient's join screen
(`/join/:slug`), voting, ranking, tallying and the results screen are not built, so do not go
looking for them on a fresh deploy — see the *What you can do in the app right now* section of
[README.md](README.md) for the current line between built and not.

### The promotion test — the admin account can actually administer

The acceptance criterion for this deploy is not just "the admin can log in" — it is that the
admin can **log in and promote another user**. Nothing above proves the second half, so prove
it explicitly. Use a private/incognito window for the second account so both sessions can be
open at once.

**Do this within 20 minutes of logging in as the admin.** Promote, Demote and Delete require
"sudo mode": `Consensus.Accounts.set_admin/3` and `Consensus.Accounts.delete_user/2` both call
`Accounts.sudo_mode?/2`, whose window is `@sudo_mode_minutes = 20`, and both return
`{:error, :sudo_required}` outside it. (That is a *different* window from the 10 minutes
`/users/settings` uses in §4.6.) Out of sudo mode you get an info panel — `<div
id="sudo-notice">`, *"For security, log in again to change roles or delete accounts."* — and
all three buttons render `disabled`. Clicking anyway, or replaying the event from a stale tab,
lands you back at `/users/log-in` with *"For security, log in again to change roles or delete
accounts. You will come back to Admin → Users."* — the disabled attributes are a courtesy, the
context functions are the enforcement. If the steps below bounce you to the log-in form, that
is this and not a failed deploy: log in again and resume.

- [ ] In a private window, register a second account at
      `https://<FLY_APP_NAME>.fly.dev/users/register`. Note its username.
- [ ] In that same private window, visit `https://<FLY_APP_NAME>.fly.dev/admin/users` → it
      must redirect to `/` (a signed-in non-admin is sent home, not to the log-in form), and
      the header must show **no Admin link**.
- [ ] In your normal window, log in as the admin (`ADMIN_USERNAME`, default `aheld`) at
      `https://<FLY_APP_NAME>.fly.dev/users/log-in`.
- [ ] Go to `https://<FLY_APP_NAME>.fly.dev/admin/users`. The new account is listed with role
      **`member`**, and a **Promote** button next to it.
- [ ] Click **Promote** and accept the browser confirmation prompt
      (`Make <username> an admin?`). Expect the flash `<username> is now an admin.`
- [ ] **The role badge flips to `admin`** on that row, without a page reload, and the subtitle
      count of admins goes up by one. The **Demote** button replaces **Promote**.
- [ ] Back in the private window, reload any page as the promoted user. Promotion does *not*
      disconnect that user's live sessions, so the header only picks up the new role on a
      remount — after the reload, the **Admin** link must appear.
- [ ] Click it: `https://<FLY_APP_NAME>.fly.dev/admin/users` now loads for the promoted user.
- [ ] Optional cleanup: as either admin, demote the throwaway account again. Unlike promotion,
      a **demotion disconnects that user's live sessions** — `Accounts.set_admin/3` returns
      their session tokens and the LiveView broadcasts a disconnect — so the private window
      remounts on its own and the **Admin** link disappears without you touching it. They stay
      logged in; they just stop being an admin everywhere at once. The last remaining admin
      cannot be demoted at all — its **Demote** button is disabled, and the server refuses with
      *"You cannot remove the last admin — promote someone else first."*
- [ ] Optional cleanup: as the admin, **Delete** the throwaway account. The button only shows
      for a non-admin who is not you, so demote it first if you promoted it. Expect the flash
      `<username> was deleted.` and the row to disappear — that frees the email address for
      re-registration, which is the recovery path §7 describes. Deletion **also** disconnects
      that user's live sessions, exactly as demotion does, so the private window remounts on
      its own and lands on the log-in form.
- [ ] Last, confirm the audit trail reached the logs. Every promote, demote and delete writes
      one line, and so does every refusal:

```bash
fly logs --app <FLY_APP_NAME> | grep '\[audit\]'
```

  A success is `[info] [audit] grant_admin actor_id=... actor="..." target_id=... target="..."`
  (or `revoke_admin` / `delete_user`); a refusal is `[warning] [audit] <action> REFUSED
  <reason> ...`, where `<reason>` is one of `:sudo_required`, `:unauthorized`, `:last_admin`,
  `:is_admin` or `:self`. These are your record of who changed whose role — Fly retains logs
  for a limited window, so ship them somewhere durable if you ever need them beyond that.

### The durability test — do this once, now

This is the check that proves the database really lives on the volume rather than in the
container filesystem. Discovering otherwise during a real deploy is much worse.

- [ ] Signed in as the admin, create a group at `/groups/new` (any title, any deadline chip) and
      add one option to it at the next screen — you do not need to finish the wizard or publish
      it; a `:draft` is enough. Note its title.
- [ ] Restart the Machine:

```bash
fly apps restart <FLY_APP_NAME>
```

- [ ] Reload `https://<FLY_APP_NAME>.fly.dev/`. **Your draft group must still be listed under
      `ACTIVE`, tagged `DRAFT`.** If it is gone, `DATABASE_PATH` is outside the mount — see the
      troubleshooting table below.

---

## 7. Day-2 operations

### Logs

Tail live:

```bash
fly logs --app <FLY_APP_NAME>
```

### A shell on the Machine

```bash
fly ssh console --app <FLY_APP_NAME>
```

The release lives in `/app`, the database in `/data/consensus.db`. Note the runtime image is
Debian slim and runs as `nobody` — there is no `sqlite3` CLI installed.

### A remote IEx session against the running app

This attaches a shell to the live BEAM, so you can call `Consensus.Accounts.list_users()`,
inspect state, and so on:

```bash
fly ssh console --pty -C "/app/bin/consensus remote" --app <FLY_APP_NAME>
```

Be careful: this is production, and anything you evaluate runs for real.

### Re-run seeding by hand

Not normally needed — every boot seeds automatically — but `Consensus.Release.seed/0` exists
for the times you are already on the machine. It is idempotent and never modifies an existing
user. Note it runs `Consensus.BootCheck.run!/0` first, as `Consensus.Release.migrate/0` and
`Consensus.Release.rollback/2` also do: `bin/consensus eval` starts a fresh node that never
goes through the application's own boot path, so without that call an unwritable volume would
be reported to you as a connection-pool error. If this command fails with `Cannot write the
SQLite database (...)`, that is the preflight talking and §8 has the row:

```bash
fly ssh console -C "/app/bin/consensus eval 'Consensus.Release.seed()'" --app <FLY_APP_NAME>
```

### Someone forgot their password

Their self-service path is the magic link at `/users/log-in` — it confirms the account, signs
them in, and *removes* any password it finds, so they can set a new one under Settings. **That
path needs a mail provider, and this deployment does not have one** (see the troubleshooting
row on magic-link email below), so on a stock deploy no link is ever delivered.

The lever you actually have is **Delete**, on `/admin/users`. Deleting the account frees its
email address and its username, so the person can simply register again. Session tokens go
with the row and the deleted user's live sessions are disconnected. **This also destroys every
activity group that person organized** — `activity_groups.organizer_id` cascades on delete, and
each group's own activities cascade with it — so Delete is not a safe recovery lever for an
organizer with a live or completed session; only use it for an account that has not built
anything yet, or accept that its groups go with it. The guard rails: the button only appears for a
non-admin who is not you, and `Consensus.Accounts.delete_user/2` refuses both cases
server-side as well — demote an administrator before deleting them. This is deliberate; see
[docs/decisions.md](docs/decisions.md) D-015.

**You must be in sudo mode to use it.** `delete_user/2` (and `set_admin/3`) require your own
authentication to be under 20 minutes old and return `{:error, :sudo_required}` otherwise; out
of the window the button is disabled behind a `#sudo-notice` panel and the server refuses the
event regardless. If you are helping someone at 2am off a session you opened that afternoon,
log in again first. Every attempt, successful or refused, leaves an `[audit]` line in
`fly logs` — see the end of §6.

If you would rather not destroy the account, the alternative is to configure a real mail
provider in `config/runtime.exs` and redeploy, after which the magic link works properly.

### Volumes and snapshots

Fly takes a snapshot of every volume daily, automatically. Retention is 1–60 days and
**defaults to 5**. This app wants 30 — long enough that silent corruption on a low-traffic app
cannot age out over a long weekend — and asks for it in two places, because neither one covers
the other:

- `[[mounts]]` in [fly.toml](fly.toml) sets `snapshot_retention = 30`. That governs a volume
  **Fly creates**, during a deploy that finds none.
- `--snapshot-retention 30` on the `fly volumes create` in §2.6, and again on the restore in
  R4 below. Those volumes are created by hand, before or outside a deploy, so they take the
  flag's value — or the 5-day default if you omit it.

The consequence worth internalising: **a volume's retention is a property of that volume, set
when it was created.** Editing `fly.toml` does not retroactively change one, and neither does
redeploying. Check it rather than assume it, and fix it in place if it is wrong.

See <https://fly.io/docs/volumes/snapshots/>.

List volumes and get `<VOLUME_ID>` (the `vol_...` string):

```bash
fly volumes list --app <FLY_APP_NAME>
```

Check what retention that volume actually has:

```bash
fly volumes show <VOLUME_ID> --app <FLY_APP_NAME>
```

Change it, on an existing volume, with no redeploy and no downtime:

```bash
fly volumes update <VOLUME_ID> --snapshot-retention 30 --app <FLY_APP_NAME>
```

List the snapshots of that volume, giving you `<SNAPSHOT_ID>`:

```bash
fly volumes snapshots list <VOLUME_ID>
```

Take one on demand — do this before any risky migration:

```bash
fly volumes snapshots create <VOLUME_ID>
```

Pull a copy of the database to your laptop — a snapshot is a block-level copy and is not
transactionally consistent with SQLite's WAL, so an off-box file copy is the more trustworthy
backup:

```bash
fly sftp get /data/consensus.db ./prod.db --app <FLY_APP_NAME>
```

### Restoring from a snapshot — READ ALL OF THIS FIRST

> **Untested against a live app.** Everything in §0–§6 was walked through against a real
> deployment. This procedure was **not** — this machine has flyctl 0.4.79 installed but is not
> logged in, so every command and flag below was verified against `fly <command> --help` and
> against Fly's published guides, and **the sequence itself has never been executed end to
> end.** It is also the only destructive procedure in this document: steps R5 and R6 delete
> your Machine and then permanently delete a volume. Read it through completely before you
> run the first command, and do not improvise the order.

Two facts the whole procedure turns on:

1. **A restore always creates a *new* volume.** `fly volumes create --snapshot-id` never writes
   back into an existing volume, and there is no command that does.
2. **A Machine's mount is bound to a volume *ID*, not to the name `consensus_data`.** The
   `source = 'consensus_data'` in `[[mounts]]` is only consulted when Fly has to *pick* an
   unattached volume — that is, when the Machine is **created**. From then on the Machine holds
   one specific `vol_...`. Creating a second volume called `consensus_data` therefore reattaches
   **nothing**, and neither of the obvious nudges helps:
   - `fly deploy` cannot swap it. Fly is explicit: *"If a Machine has a mounted volume,
     `fly deploy` can't be used to mount a different one."* (This is the same statement as the
     last row of §8.)
   - `fly apps restart` cannot swap it either — `fly apps restart --help` describes it as
     *"Perform a rolling restart against all running Machines"*, and a rolling restart re-runs
     the Machine's **existing** configuration, mount included.

   So a restore on this single-Machine app means **destroying and recreating the Machine**. There
   is no in-place option.

Expect downtime from R5 to the end of R7 — a few minutes, plus the deploy.

- [ ] **R1 — Get an off-box copy first, if the Machine is still up.** This is the one checkpoint
      that does not depend on Fly at all. Skip only if the app will not boot.

```bash
fly sftp get /data/consensus.db ./prod-before-restore.db --app <FLY_APP_NAME>
```

- [ ] **R2 — Snapshot the current volume before touching anything.** Even a corrupted volume is
      worth a snapshot: it is your undo if you restore the wrong one.

```bash
fly volumes snapshots create <VOLUME_ID>
```

  **Checkpoint:** it appears in the list, with today's timestamp. Do not continue until it does.

```bash
fly volumes snapshots list <VOLUME_ID>
```

- [ ] **R3 — Write down the four identifiers** you are about to use, and keep them in front of
      you. `<VOLUME_ID>` is the volume you are replacing, `<SNAPSHOT_ID>` is the one you want to
      go back to, `<MACHINE_ID>` is the Machine, and `<REGION>` must match §2.1.

```bash
fly volumes list --app <FLY_APP_NAME>
```

```bash
fly volumes snapshots list <VOLUME_ID>
```

```bash
fly machine list --app <FLY_APP_NAME>
```

- [ ] **R4 — Create the restored volume. This step is not destructive** — the app keeps serving
      off the old volume while it runs, so you can stop here and abort with nothing lost.
      `--region` is required in spirit if not in syntax: a volume in another region can never be
      mounted by this Machine, and this is the same region you used in §2.6. `--size 1` matches
      `initial_size = '1gb'`. `--snapshot-retention 30` matters for the same reason it did in
      §2.6 — this is a hand-created volume, so without the flag your *restored* database
      silently drops to 5-day snapshot retention, which is precisely the wrong moment to
      shorten your safety net.

```bash
fly volumes create consensus_data --snapshot-id <SNAPSHOT_ID> --region <REGION> --size 1 --snapshot-retention 30 --app <FLY_APP_NAME>
```

  flyctl asks the same single-volume-per-app confirmation as §2.6. Answer **yes**.

  **Checkpoint:** `fly volumes list` now shows **two** volumes named `consensus_data` — the old
  one attached to the Machine, the new one unattached. Record the new one's id as
  `<NEW_VOLUME_ID>` and check it against the id flyctl just printed. Getting these two mixed up
  in R6 is how you lose the data.

```bash
fly volumes list --app <FLY_APP_NAME>
```

- [ ] **R5 — Destroy the Machine. Downtime starts here.** `fly machine destroy` requires a
      stopped Machine unless you pass `-f` (`fly machine destroy --help`: *"requires a machine
      to be in a stopped or suspended state unless the force flag is used"*), so stop it
      first. Stopping is also what closes SQLite cleanly and checkpoints the WAL — which is
      the entire reason to stop rather than force-destroy.

      **Pass `-s SIGTERM` explicitly.** `fly machine stop --help` documents
      `-s, --signal string  Signal to stop the machine with (default: SIGINT)` — a *different*
      signal from the `kill_signal = 'SIGTERM'` in `fly.toml`, which is what Fly sends when
      **Fly** stops the Machine during a deploy or a restart. Do not spend the one shutdown
      that matters working out which layer wins: name the signal. `--timeout 30` mirrors
      `kill_timeout = '30s'`, the grace period before SIGKILL.

```bash
fly machine stop <MACHINE_ID> -s SIGTERM --timeout 30 --app <FLY_APP_NAME>
```

```bash
fly machine destroy <MACHINE_ID> --app <FLY_APP_NAME>
```

  **Checkpoint:** `fly status` lists **no** Machines, and `fly volumes list` shows both volumes
  now unattached.

```bash
fly status --app <FLY_APP_NAME>
```

- [ ] **R6 — Destroy the old volume. This is the irreversible step.** It has to happen before the
      redeploy: with two unattached volumes named `consensus_data`, which one the new Machine
      picks up is not something you get to choose. **Paste `<VOLUME_ID>` and read it back against
      what you wrote down in R3 — this is the old volume, not `<NEW_VOLUME_ID>`.** Its data is
      permanently deleted; R2's snapshot is what still stands behind it.

```bash
fly volumes destroy <VOLUME_ID>
```

  **Checkpoint:** exactly one volume named `consensus_data`, unattached, and its id is
  `<NEW_VOLUME_ID>`. Do not continue until the list shows exactly one.

```bash
fly volumes list --app <FLY_APP_NAME>
```

- [ ] **R7 — Recreate the Machine.** With no Machine and exactly one unattached
      `consensus_data`, this is §4.1's path replayed — Fly *creates* a mount rather than
      *changing* one, which is precisely why it works here and why it would not have worked
      without R5. `--ha=false` still matters: without it you get a second Machine that has no
      volume to mount.

```bash
fly deploy --ha=false --app <FLY_APP_NAME>
```

  **Checkpoints:** the deploy output must **not** contain a line about creating a volume (if it
  does, R6 removed the wrong one, or the name does not match `[[mounts]] source`); then exactly
  one Machine `started`, with its health check passing.

```bash
fly status --app <FLY_APP_NAME>
```

  If the app fails to boot with `Cannot write the SQLite database (...)`, that is expected-ish
  and fixable — and a snapshot restore is the **most likely** way anyone ever meets that
  message, because the restored volume carries the snapshot's root-owned files and the
  Dockerfile's `chown` only ever reaches a mount that is empty. Note the report names the
  `-wal` and `-shm` sidecars separately: those are created by whoever opened the database, so
  `consensus.db` itself can look correctly owned while they do not. Apply the recursive `chown`
  from the matching row in §8 and restart.

- [ ] **R8 — Prove the restored data is what is being served.** A green health check proves the
      schema is current and the `users` table is readable; it says nothing about *which*
      database, and an empty-but-migrated one passes it just as happily. So:
  - `fly logs --app <FLY_APP_NAME>` — the migrator runs against the restored file. Expect
    `Migrations already up`, or `== Running ... change/0 forward` for any migration added after
    the snapshot was taken. Expect **no** `[seeds] created bootstrap admin` line: a restored
    database already has an admin, so `Consensus.Seeds` no-ops. A *new* bootstrap admin appearing
    here means you are looking at an empty database, not a restored one. Expect **no**
    `database is locked` line either, for the same reason — the restored file is already in
    WAL mode, so §4.2's first-boot race cannot happen on it. One appearing here is another
    sign you are looking at a freshly created empty volume.
  - Log in and confirm the content is what you expect **as of the snapshot's timestamp** — the
    admin password is whatever it was then, not whatever it was this morning.
  - Re-run **§6's durability test** in full: create a draft group, then
    `fly apps restart <FLY_APP_NAME>`, then reload `/` and confirm the draft is still listed. That
    is the check that proves the new Machine is writing to the restored volume and not to the
    container filesystem.
  - `fly volumes list` one last time: exactly one `consensus_data`, attached.

**A note on `fly scale count --with-new-volumes --from-snapshot`.** Fly's snapshots guide lists
`fly scale count --with-new-volumes --from-snapshot <SNAPSHOT_ID> 1`, and both flags do exist in
flyctl 0.4.79 (`fly scale count --help`). It is not the command for this situation. It restores a
snapshot onto volumes for **newly created** Machines; with the existing Machine still present,
`1` is a count this app already satisfies, and nothing about the running Machine's mount changes.
It is the scale-out restore path, and this app never scales out (§7, "The one rule").

### Rolling back a bad deploy

List releases; note the version of the last good one. `--image` is required — without it the
table has no image column, and the image reference is what you actually need:

```bash
fly releases --image --app <FLY_APP_NAME>
```

Redeploy that exact image. `<IMAGE_REF>` looks like
`registry.fly.io/<FLY_APP_NAME>:deployment-01ABCDEF...` and appears in that column and in the
deploy output:

```bash
fly deploy --image <IMAGE_REF> --ha=false --app <FLY_APP_NAME>
```

This rolls back **code**, not **data** — a migration that already ran is still applied. If the
bad release migrated destructively, you need the snapshot path above, not this. Fly's own
guide: <https://fly.io/docs/blueprints/rollback-guide/>

### The one rule: never more than one Machine

**Never run `fly scale count 2`. Never deploy without `--ha=false`.**

Fly is explicit that *"A Machine can only mount one volume at a time and a volume can be
attached to only one Machine"* (<https://fly.io/docs/volumes/overview/>), and that volumes do
not replicate. A second Machine therefore gets its own, *different* volume with its own,
*empty-then-diverging* `consensus.db`. Fly's load balancer would send some users to one
database and some to the other, and there is no merge. You would not get an error — you would
get quietly split data.

Fly's resilience guidance genuinely does recommend two or more Machines
(<https://fly.io/docs/blueprints/resilient-apps-multiple-machines/>), and single-file SQLite
cannot satisfy that. This is an accepted trade-off, not an oversight: one Machine, one volume,
snapshots as the recovery path, and a documented exposure to downtime and data loss if the
host fails. Changing it means moving to LiteFS or to Postgres — a project, not a flag.

Related: `auto_stop_machines = 'off'` and `auto_start_machines = false` in `fly.toml` are also
load-bearing. A stopped Machine takes the database offline and drops every open LiveView
WebSocket. Those two settings must always be flipped together — a Machine that auto-stops with
auto-start disabled never comes back (<https://fly.io/docs/launch/autostop-autostart/>).

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Deploy fails; logs show `environment variable SECRET_KEY_BASE is missing. You can generate one by calling: mix phx.gen.secret` | `config/runtime.exs` raises at boot when the secret is unset. It is a Fly **secret**, not `[env]`, so it is easy to forget on a new app. | `mix phx.gen.secret`, then `fly secrets set SECRET_KEY_BASE=<SECRET_KEY_BASE> --app <FLY_APP_NAME>`, then redeploy. Confirm with `fly secrets list`. |
| Deploy fails with a volume/mount error, or `fly status` shows the Machine failing to start | The `source` in `[[mounts]]` does not match any volume in this app or region. The volume must be named exactly `consensus_data`, in `<REGION>`. | `fly volumes list --app <FLY_APP_NAME>`. If it is missing or misnamed: `fly volumes create consensus_data --region <REGION> --size 1 --app <FLY_APP_NAME>`. Volume names allow only alphanumerics and underscores. |
| Boot fails with `Cannot write the SQLite database (<reason>)`, followed by a `refused:` line, the `DATABASE_PATH`, each database file's uid/gid/mode, `release user: nobody (uid 65534)` and a `chown` command | The release runs as `nobody` (uid 65534) and something under the mounted volume belongs to root. The Dockerfile's `RUN mkdir -p /data && chown nobody:root /data` only reaches the *volume* when the mount is empty — that is the only case a container runtime copies the image directory's ownership onto it. A volume restored from a snapshot, one carrying a `lost+found`, or one written to during a root `fly ssh console` session all defeat it. `Consensus.BootCheck.run!/0` probes before the repo starts and raises this instead of letting Ecto emit eleven `database_open_failed` lines and a `DBConnection.ConnectionError` about connection pools — which reads like a pool-size problem and is not. Read the `refused:` line: it names the exact path, which may be the directory, the database, or just the `-wal`/`-shm` sidecars (those are created by whoever opens the database, so `consensus.db` can look correct while they do not). Historically the same misconfiguration surfaced as `** (Exqlite.Error) unable to open database file`; if you see *that* instead of the preflight message, you are running an image built before the preflight existed, and the cause and fix are identical. | `fly ssh console -u root -C "chown -R 65534:0 /data" --app <FLY_APP_NAME>`, then `fly apps restart <FLY_APP_NAME>`. The `-R` is the point — fixing only the file the `refused:` line named leaves the next boot failing on its sibling. If the message says the directory *does not exist*, the volume is not mounted at all — check `[[mounts]] destination` against `DATABASE_PATH` and see the row above. |
| Boot fails with `Cannot write the SQLite database (:eacces)` and the `refused:` line names **`/data/consensus.db-wal` or `/data/consensus.db-shm`, not `/data/consensus.db`** — and the `database files:` block shows `consensus.db` as `uid 65534:gid 0` while a sidecar is `uid 0:gid 0` | Same misconfiguration as the row above, in the shape that is easiest to misdiagnose, because the database file itself looks perfectly healthy and `ls -l /data/consensus.db` tells you nothing is wrong. `config/runtime.exs` pins `journal_mode: :wal`, so SQLite must open **and write** `consensus.db-wal` and `consensus.db-shm` beside the database; it cannot start without write access to all three. Ownership is per-file, so a sidecar can belong to root while the database does not — which is why `Consensus.BootCheck.run!/0` probes the whole WAL set (`DATABASE_PATH`, `-wal`, `-shm`) rather than just `DATABASE_PATH`, and reports whichever path actually refused. Note what does **not** cause this: running `sqlite3` as root over `fly ssh console` is safe, because SQLite `fchown`s a journal it creates to match the database file's owner precisely so a maintenance session cannot strand the daemon. The reachable causes are a root `cp`/`tar`/rsync restore that preserves its own ownership, a non-SQLite root process writing to a sidecar path, or root having created the database in the first place. A restored snapshot (§7 R7) is the most common route. Sidecars are checkpointed away on a clean shutdown, so they may be absent entirely on a healthy machine — their absence is not a symptom. | Identical to the row above, and the **`-R` is the whole point**: `fly ssh console -u root -C "chown -R 65534:0 /data" --app <FLY_APP_NAME>`, then `fly apps restart <FLY_APP_NAME>`. Chowning only the one path the `refused:` line named leaves the next boot failing on its sibling — the preflight halts at the first refusal, so it reports one path at a time even when all three are wrong. Do not delete the sidecars to "clean up": a `-wal` holds committed transactions that have not been checkpointed into the database yet, and removing it discards them. |
| Boot fails with `<dir> is not a mount point — it is part of the container filesystem.` | `Consensus.BootCheck.run!/0` compared the device id of `DATABASE_PATH`'s directory against `/` and found them identical: no volume is mounted there, so SQLite would write into the container's own filesystem. Everything would otherwise *appear* to work — the app boots, migrates and seeds an admin — and the next deploy would silently destroy all of it, which is why this **raises** rather than warns whenever `FLY_APP_NAME` is set. Usual causes: `[[mounts]]` `source` naming a volume that does not exist in this app's region, `destination` not being a prefix of `DATABASE_PATH`, or a Machine created before the mount was configured. | `fly volumes list --app <FLY_APP_NAME>` — confirm one volume named exactly `consensus_data`, in `<REGION>`, attached to the Machine. Then check `[[mounts]] destination = '/data'` is a prefix of `[env] DATABASE_PATH = '/data/consensus.db'` in `fly.toml`, commit and redeploy. If the volume exists but the Machine was created without it, a deploy cannot attach it — that is the last row of this table, and §7's restore procedure (R5–R7) is the sequence that fixes it. Grep production logs for `is not a mount point`, not for any older wording. |
| App works, but **all data vanishes on every deploy** | `DATABASE_PATH` points outside the mount, so SQLite writes into the container filesystem, which is replaced by each new image. | `DATABASE_PATH` must be `/data/consensus.db` — inside `[[mounts]] destination = '/data'`. Fix `[env]` in `fly.toml`, commit, redeploy. Verify with §6's durability test. |
| Page loads, but LiveView never connects: content is static, the browser console shows repeated WebSocket failures, and `fly logs` shows origin-check rejections | `PHX_HOST` is wrong or unset. Phoenix defaults to `check_origin: true`, validating against the endpoint's `:url` host — which `config/runtime.exs` takes from `PHX_HOST`, falling back to `example.com`. Nothing raises; it just silently mismatches. | Set `[env] PHX_HOST = '<FLY_APP_NAME>.fly.dev'` in `fly.toml` to exactly the hostname in your browser's address bar (or your custom domain). Commit, redeploy. |
| `fly status` says the Machine is `started`, but the URL times out or returns a Fly 502 | Either the endpoint bound to loopback instead of all interfaces, or `PORT` ≠ `internal_port`. Fly Proxy reaches the Machine over its private IPv6 address, so a `{0,0,0,0,0,0,0,1}` bind is unreachable. | `config/runtime.exs` must keep `ip: {0, 0, 0, 0, 0, 0, 0, 0}` (the generator default — do not "fix" it to the commented-out loopback value). And `[env] PORT` must equal `[http_service] internal_port`; both are `8080` here. |
| `** (Exqlite.Error) database is locked`, **once or twice, in the first second of the app's very first boot on a new volume** — immediately above the `== Running ... CreateUsersAuthTables` line, and never again on any later boot | **Not a fault; no action needed.** The pool's five connections open at once and each runs `PRAGMA journal_mode = wal` while connecting. On a brand-new database file that pragma converts the journal mode and needs an exclusive lock — and `Exqlite.Connection.do_connect/2` applies the journal-mode pragma eleven steps *before* it applies the busy timeout, so the losers of the race get a zero-wait `SQLITE_BUSY` rather than waiting out `busy_timeout: 5_000`. `DBConnection` reconnects at once and boot continues. Reproduced on this repository's release image against three independent empty volumes, which printed 2, 1 and 2 lines respectively; both the count and which `db_conn_N` loses vary between otherwise identical boots. Once the file is in WAL mode the pragma takes no lock, which is why a second boot is clean. Note this makes `config/runtime.exs`'s comment — that `busy_timeout` "makes a contended write wait instead of returning `database is locked`" — true of *writes* but not of this connect-time pragma. | Nothing. Confirm it is this case and not the row below: it must be the app's **first** boot on that volume, and the same `fly logs` output must go on to show `== Running ... change/0 forward` and `[seeds] created bootstrap admin`. Restart the Machine and the lines do not come back. Do **not** run `fly status` looking for a second Machine — a deploy that just created your one Machine has not grown a second one. |
| `** (Exqlite.Error) database is locked` **on an established database** — during normal traffic, on a boot that reports `Migrations already up`, or recurring rather than once at startup | A genuinely different problem from the row above. SQLite allows one writer at a time. `config/runtime.exs` sets `journal_mode: :wal` and `busy_timeout: 5_000` in prod, so a normal contended write waits rather than failing — seeing this on an existing database means either a write held the lock for over 5 seconds, or **something else has the file open**. | First: `fly status` — if there is more than one Machine, that is the cause; scale back to one immediately (see §7). Otherwise look for a long-running transaction or a migration running while traffic is served, and check you do not have an `fly ssh console` session holding the DB open. |
| The first push (§1.6/§1.7) is rejected: ``! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)`` | Your `gh` credential has `repo` but not `workflow`, and `gh`'s default git protocol is HTTPS, so the push is authenticated with exactly that token. This push is the one that *creates* `.github/workflows/` — it has never been committed — and GitHub gates creating or updating a workflow file on the `workflow` scope. `gh`'s documented minimum scopes are `repo`, `read:org`, `gist`, so a stock `gh auth login` hits this. | `gh auth refresh -s workflow`, then re-run `gh auth status` and confirm `workflow` appears under `Token scopes:`. Then just push again: `git push -u origin main`. **The GitHub repository already exists and the `origin` remote is already set — do NOT re-run `gh repo create`**; it will either error that the name already exists or leave you with a second, empty repository. Confirm with `git remote -v` first. Pushing over SSH avoids the scope check entirely, so `git remote set-url origin git@github.com:<GITHUB_USER>/<REPO_NAME>.git` is a valid alternative if you have a key on the account. §1.8 onward assumes the push landed — do not continue until `git status` says your branch is up to date with `origin/main`. |
| GitHub Actions: `deploy` job fails with an authentication or "no access token" error | `FLY_API_TOKEN` is missing, was pasted without the leading `FlyV1 ` prefix, or has expired. | Regenerate: `fly tokens create deploy -x 999999h --app <FLY_APP_NAME>`, copy the **whole** string including `FlyV1 `, then `gh secret set FLY_API_TOKEN --app actions`. Re-run the workflow with `gh run rerun --failed`. |
| GitHub Actions: nothing happens at all on push | You are not on `main`. The workflow's only push trigger is `branches: [main]`. | `git branch --show-current`; rename with `git branch -M main` and push, or open a PR into `main`. You can also force a run: `gh workflow run "Fly Deploy"`. |
| GitHub Actions: `deploy` never starts | The `test` job failed, and `deploy` has `needs: test`. This is the gate working. | `gh run view --log-failed`. To reproduce locally you need every check across **both** jobs in [.github/workflows/ci.yml](.github/workflows/ci.yml), not just the mix ones. `test` job, in order, with `MIX_ENV=test`: `mix deps.get --check-locked`, `mix deps.unlock --check-unused`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Separate `docker` job: `docker build -t consensus:test .` **and then the boot smoke test** — the build alone is not what CI asserts. Mirror it with `docker run -d --name consensus-smoke --tmpfs /data:rw,mode=0750,uid=65534,gid=0 -e DATABASE_PATH=/data/consensus.db -e SECRET_KEY_BASE="$(openssl rand -base64 48)" -e PHX_HOST=localhost -e PORT=4000 -p 4000:4000 consensus:test`, then `curl localhost:4000/health` (expect `ok`); clean up with `docker rm -f consensus-smoke`. Do not "fix" a failure there by running the container as root — a root-owned `/data` is exactly what the boot preflight exists to reject. Note `mix precommit` is **not** the same either: it *rewrites* files (`mix format`, `mix deps.unlock --unused`), never asserts `--check-locked`, and does not build or boot the image. |
| Deploy succeeded, but a new migration "did not run" | Migrations run at boot only when `RELEASE_NAME` is set — `skip_migrations?/0` in `lib/consensus/application.ex` returns `true` otherwise. The release start script `/app/bin/server` sets it. If the Dockerfile's `CMD` was changed away from `["/app/bin/server"]`, or the container is started some other way, migrations are skipped silently and the app boots against the old schema. (This is also why `mix phx.server` on your laptop does not auto-migrate.) | Confirm the Dockerfile still ends with `CMD ["/app/bin/server"]`. To check what actually ran: `fly logs` right after a deploy should show a `== Running ... change/0 forward` line, or `Migrations already up`. To force one by hand: `fly ssh console -C "/app/bin/migrate" --app <FLY_APP_NAME>`. |
| Boot fails with `could not seed the bootstrap admin user` | `Consensus.Seeds` could not create the admin — most often because `ADMIN_EMAIL` is already taken by a different account, or `ADMIN_USERNAME` collides. | Read the changeset errors in the log. Pick a different `ADMIN_EMAIL`/`ADMIN_USERNAME` via `fly secrets set`, or fix the conflicting row over a remote IEx session. |
| The default-password banner is still showing after you changed the password | The banner is computed from `Seeds.admins_with_default_password/0` at LiveView mount (and again after a role change), never per render — so an open tab keeps its stale value. | Reload `/admin/users`. If it persists, read the banner text: it names every admin account still on the default, and the account you changed will not be among them. |
| Magic-link login emails never arrive, and boot logs warn `RESEND_API_KEY is not set` | The provider (Resend, D-039) is configured but its secret is missing, so `config/runtime.exs` fell back to `Swoosh.Adapters.Logger`: each send succeeds and logs `New email delivered to <address>`, the body and therefore the link is not logged, and nothing reaches an inbox. | `fly secrets set RESEND_API_KEY=re_...` then redeploy. Confirm with `fly secrets list`. Meanwhile password login is the supported path, and for someone genuinely locked out use **Delete** on `/admin/users` (§7). |
| Magic-link emails still never arrive, but there is **no** boot warning | The key is set, so the app is using Resend — and Resend is rejecting the messages. Almost always the sender: Resend refuses a `From` whose domain is not verified in its dashboard. If `MAIL_FROM` is unset the sender is `onboarding@resend.dev`, which Resend delivers **only** to the address that owns the Resend account, so a successful test to yourself proves nothing about anyone else. | Verify your domain in the Resend dashboard, then `fly secrets set MAIL_FROM=hello@your-verified-domain.com`. Check `fly logs` for the `could not deliver` line that `Consensus.Accounts.UserNotifier` writes — invariant 9 means a rejected send is logged rather than raised, so it will not show up as an error page. |
| GitHub Actions: `deploy` fails with `Could not find App`, or deploys somewhere unexpected | The `fly.toml` you edited in §2.3 was never committed, so the repository — which is what Actions checks out — still says `app = 'consensus-app'`. `fly deploy` from your laptop keeps working, which makes this look like a CI-only problem. | `git status --short fly.toml` and `git show HEAD:fly.toml \| grep ^app`. Then do §2.4: `git commit -am "Point fly.toml at <FLY_APP_NAME>"` and `git push`. Re-run with `gh run rerun --failed`. |
| `fly deploy` refuses, mentioning an existing mounted volume | Fly states: *"If a Machine has a mounted volume, `fly deploy` can't be used to mount a different one."* A Machine's mount is bound to a volume **ID**, fixed when the Machine was created — not to the name `consensus_data`. So this is what you get whenever you changed `[[mounts]]` `source`/`destination` after the Machine existed, or created a replacement volume and expected a deploy to pick it up. `fly apps restart` does not help either: it is a *"rolling restart against all running Machines"*, which re-runs the existing Machine config, mount included. | If you only meant to keep the current data: revert the mount change in `fly.toml` and redeploy. If you actually want the Machine on a different volume, there is no in-place move — snapshot first, then destroy and recreate the Machine. §7's **"Restoring from a snapshot"** is that sequence written out with checkpoints (R1–R8); follow it rather than improvising, and note it is labelled untested. |

---

## Appendix A — placeholder cheat sheet

| Placeholder | What it is | Where it first appears |
|---|---|---|
| `<GITHUB_USER>` | Your GitHub username or organisation | 1.7 |
| `<REPO_NAME>` | The GitHub repository name, e.g. `consensus` | 1.7 |
| `<REGION>` | Fly three-letter region code from `fly platform regions`, e.g. `iad` | 2.1 |
| `<FLY_APP_NAME>` | Globally unique Fly app name; becomes `<FLY_APP_NAME>.fly.dev` | 2.2 |
| `<SECRET_KEY_BASE>` | The 64-char string from `mix phx.gen.secret` | 3.2 |
| `<STRONG_ADMIN_PASSWORD>` | Your admin password, **≥12 characters** | 3.3 |
| `<YOUR_EMAIL>` | A real email address for the admin account | 3.3 |
| `<FLY_DEPLOY_TOKEN>` | Output of `fly tokens create deploy`, **including the leading `FlyV1 `** | 5.1 |
| `<VOLUME_ID>` | `vol_...` identifier from `fly volumes list` — in §7's restore, **the old volume you are replacing** | 2.7 |
| `<SNAPSHOT_ID>` | Identifier from `fly volumes snapshots list` | 7 |
| `<NEW_VOLUME_ID>` | `vol_...` of the volume created from the snapshot in R4 — **the one you must not destroy** | 7 (R4) |
| `<MACHINE_ID>` | Machine id from `fly machine list`; this app has exactly one | 7 (R3) |
| `<IMAGE_REF>` | `registry.fly.io/<FLY_APP_NAME>:deployment-...` from `fly releases` | 7 |

Note: app-scoped `fly` commands here pass `--app <FLY_APP_NAME>` explicitly. If you run them
from the repository root, flyctl reads the app name out of `fly.toml` and you can drop the
flag — but being explicit is what stops you from operating on the wrong app. Commands that
take a volume or snapshot ID (`fly volumes snapshots ...`) do not need it.

## Appendix B — official documentation

- SQLite on Fly (why there is no `release_command`) — <https://fly.io/docs/elixir/advanced-guides/sqlite3/>
- Elixir getting started — <https://fly.io/docs/elixir/getting-started/>
- Continuous deployment with GitHub Actions — <https://fly.io/docs/launch/continuous-deployment-with-github-actions/>
- `fly.toml` configuration reference — <https://fly.io/docs/reference/configuration/>
- `fly deploy` reference — <https://fly.io/docs/flyctl/deploy/>
- Volumes overview — <https://fly.io/docs/volumes/overview/>
- Volume snapshots — <https://fly.io/docs/volumes/snapshots/>
- Autostop / autostart — <https://fly.io/docs/launch/autostop-autostart/>
- Resilient apps use multiple Machines (the guidance this app knowingly departs from) — <https://fly.io/docs/blueprints/resilient-apps-multiple-machines/>
- Rollback guide — <https://fly.io/docs/blueprints/rollback-guide/>
- Pricing — <https://fly.io/docs/about/pricing/>
- Phoenix deploying with releases — <https://hexdocs.pm/phoenix/releases.html>
