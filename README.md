# Consensus

A Phoenix 1.8 / LiveView application: SQLite-backed, deployable to a single Fly.io machine,
with username-or-email authentication, an admin area, and the beginning of the actual
product — an organizer can sign up, build a titled activity group with a hard deadline, fill
it with options (typed by hand or pasted as a URL that gets its title/description/image
pulled from the page automatically), review and reorder the pool, and publish it to a share
link — and the people he shares it with can open it with no account, vote, and watch the tally
move live. A typed option name also gets an assisted lookup — the app offers the venue's
link, found in OpenStreetMap data, as a dismissible suggestion (D-052). Place *discovery* —
browsing for options you haven't thought of — is still missing, and it will never be
Yelp/Places (rejected on their terms, not their price; D-052); see *What is not built yet*
below.

**Status.** The foundation (accounts, sessions, roles, an admin area, first-boot seeding, a
Docker release image, a CI/CD pipeline) is production-ready and was committed at `8825433`
("Add the Consensus application: auth, admin area, editable home page, Fly release") — this
is a normal git repository; `git clone` gets you everything below. On top of it, the
organizer's creation flow (D-027 through D-033 in [docs/decisions.md](docs/decisions.md))
replaced the placeholder home page with the real product landing at `/`. Run `git status
--short` if you want to know exactly what is committed versus staged in your working copy at
any given moment — the two layers above were built at different times and may not both be
committed yet.

The product this is a foundation *for* — a group activity-voting PWA where an organizer
shares a link and 4–7 friends vote with no downloads and no accounts — is specified in
[docs/PRD.md](docs/PRD.md). Technical decisions are logged in
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

### What you can do in the app right now

1. Open `/` signed out — the splash screen, with **Start something** going to `/users/register`.
2. Register (username + email + password). You are signed in immediately; no email round trip
   is required.
3. `/` now shows your (empty) list of groups and a **Start something** button.
4. **Build a session:** `/groups/new` — a title and one of three computed deadline chips
   ("Tonight 5pm" / "Tomorrow 5pm" / "Thu noon", in your browser's own time zone offset).
   Submitting creates the group as a `:draft` immediately and takes you to the options
   screen — nothing is lost if you close the tab here and come back later.
5. **Add options** at `/groups/:id/options` — type a name, or paste a URL and watch its
   title, description and photo fill in from the page's OpenGraph tags a moment later. Every
   pulled field stays editable; open a row's **Edit** to change it or replace the image URL.
6. **Review** at `/groups/:id/review` — drag (or use the ↑/↓ buttons) to reorder, toggle
   anonymous voting, see the one-veto rule, and hit **Get the share link** — this is the
   moment the group leaves `:draft` and becomes `:voting`.
7. **Share** at `/groups/:id/share` shows the join link and a copy button.
8. Log out and back in: everything you built is still there, under your account.

### What is not built yet

**Place discovery** — a browse screen for options the organizer hasn't thought of. Options
are typed or pasted as a link; a typed name gets one background *lookup* (Assisted Add,
D-052 — OpenStreetMap via Overpass, a dismissible "Is this it?" suggestion), but nothing is
ever *searched for* on a dedicated screen. It will not be Yelp/Places when it comes: every
commercial place API is rejected on its terms (D-052, `docs/research/activity-discovery.md` §3).
**Friends adding options to someone else's pool** — the pool freezes when the vote opens
(D-037), and design frame `03`'s "Friends can still add" copy was changed to match. **Ranked
choice** (Borda/IRV) — the MVP tally is approval voting, which is what the ballot comp draws;
ranked choice is explicitly Post-MVP. **Real nudges** — the organizer's *Nudge* button
confirms rather than sending, because it would need mail delivery to be configured. And the
**veto floor**: nothing stops vetoes eliminating every option, which the tally reports
honestly as `:no_consensus` rather than crowning something the group struck out — since
D-051 that ending renders a designed takeover with two organizer exits (reopen the pool,
or let the app pick one at random) instead of a bare report, but Q-8 in
`docs/open-questions.md` is still open on whether it should be *prevented*.

---

## Feature tour

| Route | What it is |
|---|---|
| `/` | One route, two faces ([`ConsensusWeb.HomeLive`](lib/consensus_web/live/home_live.ex)). Signed out: the public splash, with **Start something** → registration. Signed in: the organizer's list of activity groups — `ACTIVE` (drafts and groups still voting, with a live countdown) and `PAST` (completed/cancelled). Real-time: subscribes to every active group's PubSub topic, so an edit from another tab (or, once voting exists, another participant) updates the list without a refresh. |
| `/users/register` | Sign-up: **username + email + password**. Creates the account and signs it in immediately. |
| `/users/log-in` | Two forms on one page: password log-in (the identifier field accepts **either** the username or the email), and magic-link log-in by email. |
| `/users/log-in/:token` | Magic link landing page. Always usable. When an unconfirmed account already holds a password, the page warns **before** the button is pressed that confirming here will remove that password, then confirms and signs you in (see the recovery section below). |
| `/users/settings` | Change username, email, or password. Gated by sudo mode (`:require_sudo_mode`) on top of authentication. Email changes go through a confirmation link; username changes do not — a username is an in-app identifier, not proof of controlling an inbox. |
| `/users/log-out` | `DELETE`. Deletes the session token and broadcasts a disconnect to that session's LiveViews. |
| `/groups/new`, `/groups/:id/edit` | Wizard step 1 — title and a hard deadline. Creates (or edits) a `:draft` group. See [`GroupLive.New`](lib/consensus_web/live/group_live/new.ex). |
| `/groups/:id/options`, `/groups/:id/options/:activity_id` | Wizard step 2 — the option pool, and the full-screen editor for one option. A pasted link is fetched server-side, asynchronously; a typed name is not. See [`GroupLive.Options`](lib/consensus_web/live/group_live/options.ex). |
| `/groups/:id/review` | Wizard step 3 — reorder, toggle anonymous voting, publish (`:draft` → `:voting`) or cancel. See [`GroupLive.Review`](lib/consensus_web/live/group_live/review.ex). |
| `/groups/:id/share` | The share link, shown after publishing. See [`GroupLive.Share`](lib/consensus_web/live/group_live/share.ex). |
| `/groups/:id/results` | The organizer's live results (design frame `05`): a violet countdown, the voted/waiting avatar row, the running tally with veto elimination and a violet star on whoever is ahead — on all of them, captioned `TIED FOR THE LEAD`, when the top count is shared (D-047) — plus **Close now** and a **Nudge** that is not built and says so (`disabled`, captioned `Soon`, and rendered only while somebody has still to vote). Updates over PubSub as ballots land. A `:completed` group that could not settle itself — every option vetoed, or a dead heat at the top — replaces the tally panel with a designed takeover state carrying the organizer's exits: reopen the pool, let the app rescue one at random, or break the tie by tapping a row / letting the app shuffle (D-051). See [`GroupLive.Results`](lib/consensus_web/live/group_live/results.ex). |
| `/join/:slug` | **The recipient's front door** (frame `06`), public and account-free. Name, `skip →` for anonymous, or — if you happen to be signed in — *Continue as \<username\>*. See [`JoinLive.Entry`](lib/consensus_web/live/join_live/entry.ex). |
| `/join/:slug/enter` | `POST`. The one path that mints a participant. A **controller**, not a LiveView, because a LiveView cannot write a session cookie — and the guest's identity is a signed token in that cookie, keyed by group. See [`JoinController`](lib/consensus_web/controllers/join_controller.ex). |
| `/join/:slug/vote` | The ballot: approval voting ("tap all you'd be happy with") plus at most one veto. Once cast, **the ballot is locked** (D-036) — returning here redirects to results, because the lock is a route-level fact rather than a disabled button. Two views of the same ballot — the sticker grid (default) and a swipe deck, switched from either, sharing one `Voting.cast_ballot/3` write (D-044). See [`JoinLive.Ballot`](lib/consensus_web/live/join_live/ballot.ex). |
| `/join/:slug/results` | The participant's view of the same live tally (frame `05b`), with the "Your votes are in." confirmation (it said "Your ranking is in" until D-045 — nothing in this app ranks anything). Deliberately has no "Change my ranking" button — see D-036. Its footer covers every {status} × {participation} cell — ten of them, since D-046 split `{:completed, :stranger}` on whether this mount watched the deadline pass — so a latecomer who opens the link after voting closed still gets an exit, and someone who was already reading the tally when it closed is not told they arrived too late. The D-051 endgame takeovers render here too, minus the exits — a guest gets the scene, the list and a waiting line naming the organizer. See [`JoinLive.Results`](lib/consensus_web/live/join_live/results.ex). |
| `/about` | What Consensus is and who built it ([`ConsensusWeb.AboutLive`](lib/consensus_web/live/about_live.ex)). One of the three standing pages the global footer links to (D-041), so it is reachable from the footer of every screen **except the `/join` tree**, where the footer is stripped to its two credit lines so nothing there can discard a guest's unsent ballot. Its `‹` follows the `?return_to=` the footer handed it and falls back to `/`. |
| `/how-it-works` | The five-step walkthrough of a session, from design frame `00b` ([`ConsensusWeb.HowItWorksLive`](lib/consensus_web/live/how_it_works_live.ex)), ending in a **Start something** call to action that goes to `/groups/new` signed in and `/users/register` signed out. Deliberately does **not** say friends can add options once voting opens — the pool freezes then (D-037), and plan ruling 5 makes writing true copy here a requirement rather than a preference. |
| `/privacy` | What this app stores and what it does not ([`ConsensusWeb.PrivacyLive`](lib/consensus_web/live/privacy_live.ex)): an email and username for organizers, a display name for participants (optional — a guest may vote anonymously), and **no screen, export or admin page that can report who picked what** — `Voting.tally/1` returns totals only and the context exposes no attribution function (D-035). Note the precise claim, because the page makes it precisely: this is a property of the code, not of the schema. `Consensus.Voting.Vote` does `belongs_to :participant` and a participant may carry a `display_name`, so one hand-written join in `iex` would answer the question; what does not exist is any code path, any screen or any operator tool that asks it. |
| `/feedback` | The form the two faces in the global footer open ([`ConsensusWeb.FeedbackLive`](lib/consensus_web/live/feedback_live.ex)), design frame `00c`, pre-set by `?mood=happy` or `?mood=sad` and changeable on the page. Public — no account, from any screen that carries the footer, which is everything except the `/join` tree — and it writes: `Consensus.Feedback.submit/2` stores the message, the mood, an optional name and email, `user_id` whenever the sender is signed in (the form says so, because a signed-in sender cannot decline it), and the screen you were on **only** while the default-on box stays ticked (D-042). Sending replaces the form with a full-page thank-you rather than flashing over it, and `push_patch`es to `?sent=1` so a reload or a Back does not silently drop the sender onto an empty form, and it carries the same `?return_to=` as the standing pages, so sending from step 2 of the wizard returns you to step 2. |
| `/admin`, `/admin/users` | Admin → Users ([`AdminLive.Users`](lib/consensus_web/live/admin_live/users.ex)). Lists every account; **Promote**, **Demote** and **Delete**. Refuses to demote the last admin (`{:error, :last_admin}`); both demotion and deletion disconnect that user's live sessions, and **deleting a non-admin now cascades to every activity group they organize** (see *Architecture* below). All three actions need **sudo mode** (a log-in within the last 20 minutes): out of it, the page shows a `#sudo-notice` banner and greys the buttons, and `Consensus.Accounts` refuses regardless of what the client sends. Renders the default-password banner. |
| `/admin/feedback` | Admin → Feedback ([`AdminLive.Feedback`](lib/consensus_web/live/admin_live/feedback.ex)). The triage queue for everything `/feedback` collects, newest first, unread rows on yellow. **Mark read** is reversible from the same button, and each row carries a private admin note. Neither write is sudo-gated and neither notifies anyone — the screen says so (D-043). An unsaved admin note is never destroyed by another action on the page: only the row an event actually wrote is reseeded from the database. There is no delete on the queue; clearing a spam run is `sqlite3` by hand (D-042). In the same `scope "/admin"` and the same `live_session :require_admin` as Users, so it carries both guards. |
| `/admin/dashboard` | Phoenix LiveDashboard. Mounted in **every** environment, admin-only — not left on `:dev_routes`. **It is the one route with no Consensus header or footer, and no link back into the app** — it is a third-party LiveView with its own `live_session` and its own layout, so `Layouts.app/1` never runs for it (D-041). Use the browser's back button to leave. |
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
  `register_user/2` deliberately does not), and `get_user/1`, which returns `nil` for anything
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
    disconnected. **Deleting a non-admin also cascades to `activity_groups`**
    (`organizer_id` references `users` with `on_delete: :delete_all`), which in turn cascades to
    that group's `activities` — so deleting an organizer destroys every group they built, not
    just their account. An activity someone else *added* to a group they don't organize
    survives with `added_by_id` nulled (`on_delete: :nilify_all`).

  Both also write an audit line: `[audit] grant_admin|revoke_admin|delete_user actor_id=… actor=…
  target_id=… target=…` at `:info` on success, and `[audit] … REFUSED <reason> …` at `:warning` on
  every refusal. Ids lead because usernames are mutable, and nothing password-derived is logged.
  With one machine, no external audit sink and no undo, that line is the only record of who
  promoted or deleted whom — and a run of `REFUSED :unauthorized` is what someone acting from a
  revoked session looks like. See [docs/decisions.md](docs/decisions.md) D-021.

- [`Consensus.Activities`](lib/consensus/activities.ex) — activity groups (a titled, deadlined
  pool of options) and the activities (options) inside them. Scope-first, like `Accounts`:
  functions that take an already-loaded `%Group{}` or (indirectly) `%Activity{}` check ownership
  as a **precondition in the function head** — the scope's `user_id` and the group's
  `organizer_id` are bound to the same variable, so a call on someone else's group raises
  `FunctionClauseError` rather than taking a runtime branch. `update_activity/3` and
  `delete_activity/2` are the exception: an `%Activity{}` carries only `group_id`, not the
  organizer, so those two re-read the owning group from the database instead and return
  `{:error, :unauthorized}`.

  A group's `status` moves `:draft → :voting → :completed | :cancelled`. Step 1 of the wizard
  creates the row as a `:draft` immediately, so nothing is lost to a closed tab.
  `publish_group/2` (on step 3, "Get the share link") moves it to `:voting`; that is also when
  the share link starts working. There is **no scheduler or background job** for deadline
  expiry — `maybe_complete_group/1` runs lazily on every read (`list_groups/1`, `get_group!/2`,
  `get_group_by_slug/1`), so a group whose deadline passed while nobody was looking is reported
  (and, on its first read since expiry, persisted) as `:completed` the next time anyone looks.
  Changes broadcast over `Phoenix.PubSub` on `"activity_group:<id>"`, the same pattern
  `ConsensusWeb.HomeLive` and the wizard screens use for live updates (CLAUDE.md product
  invariant 4). See D-029.

- [`Consensus.LinkPreview`](lib/consensus/link_preview.ex) — fetches a pasted URL's OpenGraph
  (falling back to `<title>`/`<meta name=description>`) so an option can be prefilled. Refuses
  non-`http(s)` URLs and any host that resolves to loopback/private/link-local — re-checked on
  every redirect hop, up to 3 — times out at 5s, caps the body at 512 KB, and **never raises**:
  every failure is `{:error, atom}`. Results and errors are both cached in ETS (6h / 5m). The
  image is stored as a **URL only** — nothing is downloaded, proxied or hosted; a dead image
  degrades to a placeholder in the UI. Callers must invoke it from `start_async`, never inline
  in a `handle_event` — it's a real network call with multi-second timeouts, and a LiveView is
  one process. See D-030.

- [`Consensus.Deadlines`](lib/consensus/deadlines.ex) — pure functions, no database. Every
  wall-clock computation in the app: the three deadline chips and the custom picker on
  `/groups/new`, the countdown, and every "closes …" label. The browser sends both its IANA zone
  name and its UTC offset in the LiveView connect params, and `Deadlines.Clock` resolves them
  **zone → offset → UTC**: with a zone the answer is right at any future date, including across a
  daylight-saving change; without one it falls back to the offset arithmetic D-031 shipped, which
  can be an hour out across a DST transition. The zone database is `:tz`, compiled in at build
  time with its updater deliberately unsupervised. See D-055, and D-031 for what it supersedes.

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

**Every screen wears a global header and footer.** `ConsensusWeb.Layouts.app/1` is the canvas, a
centred column, the flash group **and** `ConsensusWeb.Chrome.header/1` / `Chrome.footer/1` around
the screen's content — a screen contributes only `back` (its one back affordance, or `back_patch`
when back lands in the same LiveView), `context` (the header's right-hand `STEP 2 OF 3` /
`LIVE SESSION` / `ADMIN` slot, for state and never for the page's own name), `variant` and
`current_path`. The header is `sticky top-0`, because it is now the only way back on every screen;
its `⋯` account menu is a `<details>` element rather than a JS dropdown, so it works before the
LiveView socket connects. The footer carries the two feedback faces and links to `/about`,
`/how-it-works` and `/privacy` — except on the `/join` tree, where it is stripped to its two credit
lines and the wordmark goes inert, because a guest's ballot lives in socket assigns until it is
sent and every link off that screen throws it away. See D-041, which supersedes D-032 — that entry's reasoning (each
screen's header content genuinely differs) is still why the global header *coexists* with the
wizard's progress bar rather than replacing it. Styling is a hand-rolled Tailwind v4
`@theme` token system rather than daisyUI — see
[.claude/skills/design-system/SKILL.md](.claude/skills/design-system/SKILL.md) and D-028; there
is no dark theme.

**Authorization** lives in [`ConsensusWeb.UserAuth`](lib/consensus_web/user_auth.ex) and is
applied twice to every admin route, because a plug pipeline does not run for a LiveView
websocket connection:

- the `:require_authenticated_user` and `:require_admin_user` **plugs** reject the initial HTTP
  request, and
- the `:require_admin` **`on_mount` hook** on the `live_session` rejects the socket mount.

Non-admins who are already signed in are redirected to `/` (not to the log-in form, which would
be a dead end); anonymous visitors are sent to `/users/log-in` with a stored return path. See
[`router.ex`](lib/consensus_web/router.ex).

**Live updates** use `Phoenix.PubSub`. `Consensus.Activities.subscribe_group/1` subscribes the
calling process to `"activity_group:<id>"`; a successful write broadcasts `{:group_updated,
group}`, `{:activity_added, activity}`, `{:activity_updated, activity}` or
`{:activities_changed, activities}`, and `HomeLive`/`GroupLive.*` re-assign on receipt. No
polling, no manual refresh.

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
Consensus.LinkPreview.Cache                          # the ETS table Consensus.LinkPreview.fetch/1 caches into
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
`Consensus.Release.seed/0` (by hand, e.g. over `fly ssh console`). It creates a bootstrap admin
only if `Accounts.count_admins()` is `0` — keyed on the *role*, not on the username, so renaming
or re-emailing the account cannot make the next boot look like a first boot and recreate `aheld`
with the documented default password. Where an admin already exists it returns
`{:ok, %{admin: nil}}`.

---

## How authentication differs from stock `mix phx.gen.auth`

The generator was run as `mix phx.gen.auth Accounts User users` (Phoenix 1.8 scopes, magic link,
password, sudo mode). Five deliberate divergences:

**1. Users have a unique, case-insensitive `username`.** Added to the initial migration rather
than a follow-up one, because at the time the schema had never been deployed anywhere and because
SQLite cannot add a `NOT NULL` + `UNIQUE` column to a populated table without a table rewrite. The column is declared
`COLLATE NOCASE`, so `Accounts.get_user_by_username/1` is case-insensitive for free. Usernames
are 3–30 characters of `[a-zA-Z0-9_-]`.

**2. Users have an `is_admin` boolean**, changed only through
[`User.admin_changeset/2`](lib/consensus/accounts/user.ex) — which casts *nothing* but
`:is_admin`, so an admin-only endpoint can never be used to smuggle through an email, username,
or password change.

**3. Registration takes a password and signs the user in immediately.** Stock 1.8 registration is
magic-link-only: you register, then click a link in an email to get a session. That makes the app
unusable on a fresh deploy whose mail provider is not yet configured — which is the state this app
boots in until `RESEND_API_KEY` is set (see *Mail* below). So `/users/register` takes username +
email + password, and hands the populated
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
  [docs/decisions.md](docs/decisions.md) D-015. **Note this also deletes every activity group the
  person organized** — see *Architecture* above.

### Mail: Resend, but only once its key is set

The provider is **Resend** ([docs/decisions.md](docs/decisions.md) D-039).
[`config/runtime.exs`](config/runtime.exs) selects it for `:prod` **only when `RESEND_API_KEY` is
set and non-empty**, and otherwise falls back to `Swoosh.Adapters.Logger`, printing a boot warning
that names the fix. So a deploy without the secret still boots and still works — it just delivers
nothing:

```bash
fly secrets set RESEND_API_KEY=re_...
```

Only the key is a secret. **`MAIL_FROM` lives in `fly.toml`'s `[env]` block**, next to
`PHX_HOST` — it is in the header of every email you send, so there is nothing to hide, and
keeping it in the repo makes it diffable and reviewable. Fly secrets are write-only and each
`set` restarts the machine; neither is a property you want for ordinary config.

Two things bite here. **`MAIL_FROM` must be on a domain you have verified in the Resend
dashboard**, or every send is rejected by the provider; unset, it falls back to Resend's
`onboarding@resend.dev`, which only delivers to the address that owns the Resend account. And
until the key is set, magic-link login and confirm-your-email-change reach nobody — use password
login, and `Delete` on `/admin/users` for someone genuinely locked out.

The fallback is a real design decision rather than caution: mail is best-effort here (invariant 9),
so a missing mail key must never cost a boot the way a missing `SECRET_KEY_BASE` does.

Why the fallback is `Logger` and not the generated default: [`config/config.exs`](config/config.exs)
sets `Swoosh.Adapters.Local`, and [`config/prod.exs`](config/prod.exs) sets
`config :swoosh, local: false`, which stops Swoosh starting the storage process that adapter calls.
In a release the two together made **every delivery exit**, taking the calling process with it,
which would have crashed sign-up. `Logger` always succeeds and logs the recipient — not the body,
so no magic-link token reaches the logs. Belt and braces:
[`Consensus.Accounts.UserNotifier.deliver/3`](lib/consensus/accounts/user_notifier.ex) wraps the
send in a `catch`, turning both an `{:error, _}` tuple and a process **exit** into a logged
`{:error, reason}`, so no mailer failure can ever escape into a web request. See
[docs/decisions.md](docs/decisions.md) D-014.

What that does *not* buy you is delivery. Nothing reaches an inbox in production, so magic-link
log-in and the confirm-your-email-change flow go nowhere until you configure a provider in the
"Configuring the mailer" section of `config/runtime.exs`. Password log-in — the path registration
puts everyone on — works regardless, and it is also how every organizer builds and reaches their
own groups, so nothing in the creation flow above depends on mail either.

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
| `POOL_SIZE` | `config/runtime.exs`, `:prod` only | `1` | No, and **do not raise it without a measurement** (D-038). SQLite allows one write transaction across the whole file, so extra slots buy no write concurrency — they only add contenders for a lock that was never shareable, and they slow reads too. A 15-voter deadline burst measured p95 25,762 ms at `5` (with ballots lost outright) against 10.6 ms at `1`. |
| `RESEND_API_KEY` | `config/runtime.exs`, `:prod` only | unset | For real email, yes. Unset ⇒ `Swoosh.Adapters.Logger` and a boot warning; nothing is delivered but the app runs (D-039). |
| `MAIL_FROM` / `MAIL_FROM_NAME` | `config/runtime.exs`, `:prod` only — set in `fly.toml` `[env]`, **not** as a secret | `onboarding@resend.dev` / `Consensus` | Only with `RESEND_API_KEY`. The address must be on a domain **verified in Resend**; the default only delivers to the Resend account owner. |
| `DNS_CLUSTER_QUERY` | `config/runtime.exs`, `:prod` only | unset → `:ignore` | No. Irrelevant on a single machine. |
| `ADMIN_USERNAME` | [`lib/consensus/seeds.ex`](lib/consensus/seeds.ex) | `aheld` | No. Read only on a boot where the database holds **no administrator** (`Accounts.count_admins() == 0`) — normally the first boot. Ignored once any admin exists. |
| `ADMIN_EMAIL` | `lib/consensus/seeds.ex` | `aheld@example.com` | No. Same gate as `ADMIN_USERNAME`, and read on the same boot or not at all. |
| `ADMIN_PASSWORD` | `lib/consensus/seeds.ex` | `adminpass` | **Strongly recommended before the first boot.** See the security section. |

Also configured but not via environment: `Consensus.Repo` runs `journal_mode: :wal` with
`busy_timeout: 5_000` in every environment, and `default_transaction_mode: :immediate` in dev and
prod (not test, which runs under the Ecto sandbox) — SQLite permits one write transaction at a
time, and taking the write lock at `BEGIN` rather than on the first write is what lets a second,
simultaneous writer actually wait out the busy timeout instead of failing immediately. See
[docs/decisions.md](docs/decisions.md) D-013 and D-033.

---

## Testing

```sh
mix test                        # 1241 tests, 0 failures (~28s warm) — the one count in this file
mix test test/consensus/accounts_test.exs
mix precommit                   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

**The suite runs one test case at a time (`max_cases: 1` in `test/test_helper.exs`) — this is a
SQLite correctness requirement, not a performance setting.** SQLite allows exactly one write
transaction across the whole database file, and the Ecto sandbox holds each test's transaction
open for the entire test; two write-touching cases running concurrently collide by construction,
and SQLite cannot make the loser wait for a busy timeout it never gets to consult. `async: true`
on a test case is still meaningful — under the sandbox it still means its own connection and its
own rolled-back transaction — it just no longer means "runs at the same time as its neighbours."
See D-033.

Set `MIX_TEST_PARTITION=<n>` to get your own `consensus_test<n>.db` if something else may be
running the suite at the same time — this now matters more than it used to, since two
unpartitioned runs against the same file can produce real assertion failures (extra rows, wrong
counts), not just contention errors. `mix precommit` honours the variable too.

Coverage is concentrated where the divergences are: `Consensus.Accounts` (username uniqueness
and case-insensitivity, login-by-either-identifier, the last-admin guard, the sudo-mode gate on
both admin writes, `delete_user/2`'s refusals, and every branch of the magic-link rule, up to an
end-to-end pre-stuffing scenario and an assertion that no arity-2 `login_user_by_magic_link`
exists), `Consensus.Activities` (the scope-first authorization split described in *Architecture*,
publish/cancel/complete transitions, lazy deadline completion, position renumbering on delete,
and full-pool reordering), `Consensus.LinkPreview` (the SSRF guard against literal IPs and
resolved hostnames, redirect-hop re-checking, the cache, and that fetch failures never raise),
`Consensus.Deadlines` (the three chips and the countdown label across weekdays and UTC offsets,
pure — no database), `ConsensusWeb.UserAuth` (`require_admin_user/2` and `on_mount
:require_admin`), `AdminLive.Users` (including that demoting an admin severs their live sockets,
that deleting one does too — and now cascades their groups — and that the actions are refused and
visibly disabled out of sudo mode), the wizard LiveViews under `test/consensus_web/live/group_live/`
(one file per screen), `Consensus.Seeds` (idempotency and the zero-admins gate),
`Consensus.BootCheck` (against real directories under a `tmp_dir`, including a root-owned `-wal`
sidecar beside a healthy database), the settings LiveView, `ConsensusWeb.HomeLive` (both faces of
`/`), `UserSessionController`, `Consensus.Application` (asserting the supervision-tree shape —
there is no `release_command`, so that list is the only thing that migrates a release),
`HealthController` (including that it answers 503 on a pending migration and on a missing table),
`Consensus.Release` (against a throwaway repo under the test's own `tmp_dir` — never the suite
database — and pinning that `migrate/0`, `seed/0` *and* `rollback/2` all preflight),
`Consensus.Accounts.UserNotifier` (stand-in adapters that exit and that return `{:error, _}`,
neither of which `Swoosh.Adapters.Test` can reproduce), the router (asserting that every
`/admin` route carries *both* the plug and the `on_mount` guard, since dropping either is a silent
hole), `Consensus.DeployConfig` (`fly.toml` read as text, no database: `app` vs `PHX_HOST`,
`PORT` vs `internal_port`, `DATABASE_PATH` inside the mount, and the single-quoted shape `ci.yml`'s
`sed` expects), registration, log-in and confirmation.

**[`test/consensus_web/journey_test.exs`](test/consensus_web/journey_test.exs) is the one
end-to-end acceptance test**, deliberately singular: sign up → create a group → add one typed
option and one pasted-URL option → edit an option → review and publish → get the share link →
log out → log back in with a brand-new connection → confirm everything survived and nothing
leaked into another organizer's account. Per-screen tests cover their own branches; this one
exists to catch failures that only appear *between* screens.

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
[SQLite3 guide](https://fly.io/docs/elixir/advanced-guides/sqlite3/) prescribes. **This app is
deployed** — `consensus-app` on one Fly machine, served from `dinner.isourthing.com` (see
`docs/decisions.md` D-040, which also records what the first deploy actually surfaced) —
and [TODO.md](TODO.md) is the first-deploy runbook that got it there; its snapshot-restore
procedure (§7) is the one part that has still never been executed against a live app.

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
├── .claude/skills/              # elixir, phoenix, sqlite, fly-io, design-system
├── assets/                      # app.css (Tailwind v4 @theme tokens, no daisyUI), app.js
│                                 #   (sends the browser's tz offset in the LiveView connect
│                                 #   params), hooks.js, vendored heroicons/topbar
├── config/                      # config, dev, test, prod, runtime
├── docs/
│   ├── PRD.md                   # product north star (voting, ranking, results are not built)
│   ├── decisions.md             # ADR-lite technical log, D-001 through D-050
│   ├── open-questions.md
│   ├── design/                  # DESIGN-SPEC.md (visual source of truth) + per-screen extracts
│   ├── plans/                   # per-feature implementation plans, incl. creation-flow.md
│   ├── prd-technical-extracts.md    # unratified draft
│   └── technical-roadmap-v1-draft.md # unratified draft
├── lib/
│   ├── consensus/               # Accounts, Activities, LinkPreview, Deadlines, Seeds,
│   │   │                        #   Release, Repo, Application, BootCheck
│   │   ├── accounts/            # user.ex, scope.ex, user_token.ex, user_notifier.ex
│   │   ├── activities/          # group.ex, activity.ex
│   │   ├── link_preview/        # cache.ex, fetcher.ex
│   │   └── boot_check.ex        # DATABASE_PATH/volume preflight, run before Consensus.Repo
│   └── consensus_web/
│       ├── components/          # core_components.ex, layouts.ex (canvas + column + flash +
│       │                        #   the global chrome — see Architecture), chrome.ex (the
│       │                        #   global header/footer, D-041), sticker.ex,
│       │                        #   results_components.ex, layouts/root.html.heex
│       ├── controllers/         # user_session_controller.ex, health_controller.ex,
│       │                        #   join_controller.ex, error_html/json
│       ├── live/                # home_live.ex, admin_live/ (users.ex only — the home-page
│       │                        #   editor was deleted), group_live/ (the creation wizard),
│       │                        #   join_live/ (the voting loop), user_live/,
│       │                        #   about_live.ex / how_it_works_live.ex / privacy_live.ex /
│       │                        #   feedback_live.ex (the footer's standing pages)
│       ├── router.ex
│       └── user_auth.ex         # plugs + on_mount hooks; all authorization lives here
├── priv/repo/
│   ├── migrations/              # users+tokens (with username/is_admin); home_page (created,
│   │                            #   then dropped by a later migration — the home page was
│   │                            #   deleted, see decisions.md D-027); activity_groups + activities
│   └── seeds.exs                # delegates to Consensus.Seeds.run!/0
├── rel/overlays/bin/            # server (release entrypoint; sets PHX_SERVER=true) and
│                                #   migrate, plus their .bat pairs. migrate is generator
│                                #   output and is NOT in the deploy path — migrations run
│                                #   from the supervision tree; see Deployment.
└── test/                        # mirrors lib/, plus support/ (ConnCase, DataCase,
                                 #   fixtures, link_preview_stub.ex), journey_test.exs (the one
                                 #   end-to-end acceptance test), and deploy_config_test.exs,
                                 #   which reads fly.toml as text
```
