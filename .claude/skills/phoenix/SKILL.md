---
name: phoenix
description: Phoenix 1.8 and LiveView 1.2 conventions for the Consensus app — layouts (Layouts.app plus root.html.heex, no app.html.heex, no global navbar — D-032), core components, HEEx syntax ({} vs <%= %>, :if/:for), the LiveView lifecycle (mount/handle_params/handle_event/handle_info/handle_async), start_async for a network call like Consensus.LinkPreview.fetch/1, LiveView streams and the reset: true reload idiom, live_session and on_mount hooks, Phoenix 1.8 scopes (Consensus.Accounts.Scope and @current_scope, never current_user), revoking a mounted LiveView's access with UserAuth.disconnect_sessions/1, verified routes ~p including the organizer's creation-flow wizard under /groups, PubSub for real-time updates, the router pipelines in lib/consensus_web/router.ex, and testing with Phoenix.LiveViewTest (render_async, the $callers link-preview stub, journey_test.exs). Use this when adding or editing anything under lib/consensus_web/ — a LiveView, a route, a component, a template, a LiveView test — or when debugging a missing current_scope assign, a ~p route warning, a HEEx compile error, a LiveView test that fails on async assigns, or a start_async task that can't find its test stub. For button/input/card/chip/pill styling and the sticker design tokens, see the design-system skill instead.
---

# Phoenix 1.8 + LiveView in this repo

`mix phx.new consensus --database sqlite3` → `mix phx.gen.auth Accounts User users` →
`mix phx.gen.release --docker`. Phoenix 1.8.9, phoenix_live_view 1.2.8, Elixir 1.20.3, OTP 29.

A pristine copy of that generator output is the yardstick for "does Phoenix do X, or did we?" —
regenerate it into a throwaway directory whenever you need one (it is ~230 MB with deps, which is
why it is not committed):

```bash
cd "$(mktemp -d)" && yes | mix phx.new consensus --database sqlite3 >/dev/null \
  && cd consensus && yes | mix phx.gen.auth Accounts User users >/dev/null \
  && mix deps.get >/dev/null && mix phx.gen.release --docker >/dev/null && pwd
```

Never modify it, and never read it to learn *this* app — only to learn what stock ships.
Diff against it before claiming "Phoenix does X":

```bash
diff -u <reference>/lib/consensus_web/router.ex lib/consensus_web/router.ex
```

Diffed 2026-08-08 — the app has moved well past the generator, so **do not assume a file is stock**:

| Still byte-identical | Diverged |
|---|---|
| `lib/consensus_web.ex` | `components/layouts.ex` (Consensus branding, admin nav, account menu, `admin?/1`) |
| `test/support/conn_case.ex` | `components/layouts/root.html.heex` (account menu removed — see below) |
| `test/support/data_case.ex` | `router.ex` (admin scope, `HomeLive`, LiveDashboard in all envs) |
| | `user_auth.ex` (`:require_admin` / `require_admin_user`) |
| | `components/core_components.ex` — one hunk: `<.table>` is wrapped in `<div class="overflow-x-auto">` so a wide row scrolls itself instead of the page |
| | all four `live/user_live/*.ex` |

Regenerate that table with:

```bash
REF=<reference>          # the path above, the one that already ends in /consensus
for f in lib/consensus_web/components/layouts.ex lib/consensus_web/router.ex; do
  diff -q "$REF/$f" "$f" >/dev/null && echo "SAME $f" || echo "DIFF $f"
done
```

## When NOT to use this

Not for Ecto schemas/contexts/migrations (`lib/consensus/**`, `priv/repo/migrations`), not for SQLite
specifics, not for Fly.io / release / Docker work, not for the boot-time migration + seed pipeline in
`lib/consensus/application.ex`. This skill stops at the `ConsensusWeb` boundary. Also do not use it as a
LiveView tutorial — it assumes you know LiveView and only records what is *true here*.

## Web layer map

```
lib/consensus_web.ex                       # __using__(:live_view|:html|:controller|:router)
lib/consensus_web/router.ex                # pipelines, scopes, live_sessions
lib/consensus_web/user_auth.ex             # plugs + on_mount hooks (extended: admin)
lib/consensus_web/endpoint.ex
lib/consensus_web/components/
  layouts.ex                               # Layouts.app/1, avatar/1, account_menu/1, flash_group/1
  layouts/root.html.heex                   # the ONLY .heex layout file — no <script> theme toggle
  core_components.ex                       # flash, button, input, header, table, list, icon, ...
  sticker.ex                               # ConsensusWeb.Sticker — see the design-system skill
lib/consensus_web/live/home_live.ex        # "/" — splash (signed out) or group list (signed in)
lib/consensus_web/live/admin_live/         # users.ex — home_page.ex is gone (D-027)
lib/consensus_web/live/group_live/         # new.ex, options.ex, review.ex, share.ex — the
                                           #   organizer's creation wizard, see "Router" below
lib/consensus_web/live/user_live/          # login, registration, confirmation, settings (all edited)
lib/consensus_web/controllers/             # error_html.ex, error_json.ex,
                                           #   health_controller.ex, user_session_controller.ex
```

**There is no `PageController` / `PageHTML` / `page_html/` here** — the generator's `/` was replaced
by `ConsensusWeb.HomeLive`, and those files were deleted. Four controllers exist, listed above; the
only one that is not generator output is `HealthController`.

**`ConsensusWeb.HealthController` serves `GET /health` for Fly's health checker**, and it is
deliberately outside the `:browser` pipeline — no session, no CSRF token, no layout. `index/2`
is a two-step readiness check, **not** a `SELECT 1`:

1. `Ecto.Migrator.migrations/3` (with `skip_table_creation: true`, so the check never takes
   SQLite's write lock every 30 s) must report no `:down` migration, else `503 "migrations
   pending"`. A bare `SELECT 1` is a constant expression SQLite answers without touching a
   table, so a release whose boot migrator never ran would have reported 200 while `/` 500'd.
2. `SELECT 1 FROM users LIMIT 1` — one page read against a real table, whose name comes from
   `Consensus.Accounts.User.__schema__(:source)` at compile time. Correct on an empty table.

Anything else is `503 "database unavailable"`. It carries **both** a `rescue` and a
`catch :exit, reason` clause, because a dead or draining connection pool exits rather than
raising and `rescue` would miss it (same reasoning as `UserNotifier`). `config/prod.exs` lists
`paths: ["/health"]` in the `force_ssl` `exclude:`, because the prober connects over plain HTTP
to the machine's private address and a 301 could never pass. Do not move this route into
`:browser`, and do not point the check at `/`.

Ten LiveViews exist on disk today: `live/home_live.ex`, `live/admin_live/users.ex`,
`live/group_live/{new,options,review,share}.ex` (the creation wizard, D-027/D-029 through D-032),
`live/user_live/{login,registration,confirmation,settings}.ex`. `live/admin_live/home_page.ex` is
**gone** (D-027 — the admin-editable home page was deleted; `Consensus.Content` no longer exists).
`mix compile --warnings-as-errors` and `mix format --check-formatted` both exit 0 (verified
2026-08-08). The app is still being written concurrently, so `ls lib/consensus_web/live/` before
assuming a module's shape.

## Layouts: 1.8 has no `app.html.heex`, and this app has no navbar (D-032)

Phoenix 1.7 had `layouts/root.html.heex` **and** `layouts/app.html.heex`. **1.8 deleted the second one.**
There is exactly one layout template file here, `layouts/root.html.heex`, set by the `:browser` pipeline:

```elixir
plug :put_root_layout, html: {ConsensusWeb.Layouts, :root}
```

The "app chrome" is now a **function component**, `Layouts.app/1` in `layouts.ex`. It is not a layout —
LiveViews call it themselves. Every LiveView/HTML template in this app must open with it:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <.header>Page title</.header>
  ...
</Layouts.app>
```

**`Layouts.app/1` is canvas, column and flash only — nothing else.** daisyUI is gone (D-028) and
there is no global navigation bar (D-032): the design gives every screen a different header —
the home screen has a wordmark and an avatar, the wizard steps have a back button and a
three-segment progress bar, the option editor has a close button and a destructive `Remove` —
and a shared bar above all of them would either duplicate the back affordance or push the
progress bar down a row. So `app/1` renders exactly `<main>` + a centred `<div>` column +
`<.flash_group>`, and every screen draws its own header inside the `inner_block` slot. Rules
that fall out of that:

- `Layouts` is already aliased by `html_helpers/0` in `lib/consensus_web.ex`. Never alias it again.
- `attr :flash, :map, required: true` — omitting `flash=` is a compile-time error.
- `attr :current_scope, :map, default: nil` — optional to the component. `Layouts.app/1` itself
  does not read it (it renders no nav of its own); pass it anyway so a screen's own header can.
- **Two more attrs exist and neither is generator-default: `width` (`:phone`, the default 440px
  column every design frame was drawn at, or `:wide` for the desktop organizer console — a
  1280px column, not the phone column stretched) and `background` (a Tailwind class string,
  default `"bg-surface"`, the colour behind the column).** Pass `width={:wide}` on the one screen
  that needs it (the desktop console reuses `Layouts.app/1` rather than a second layout module);
  everything else takes the default.
- `<.flash_group>` lives in `Layouts` and is rendered *inside* `Layouts.app`. Never call it anywhere else.
- **There is no account menu inside `Layouts.app/1`, and no `<li :if={admin?(@current_scope)}>`
  nav item anywhere.** `Layouts.account_menu/1` is a separate function component — a `<details>`
  element (works before LiveView connects, closes on `Escape`, no JS of ours) that a screen
  renders itself, wherever the design puts it (`HomeLive` and `GroupLive.New` both call it
  today). It requires `current_scope` and renders `Layouts.avatar/1` (a circle with the user's
  upper-cased first initial — no upload, so it is always available) plus the email, an
  `<.link :if={admin?(@current_scope)} navigate={~p"/admin/users"}>Admin</.link>`, Settings and
  Log out. `Layouts.admin?/1` still exists and still means the same thing —
  `admin?(%Scope{user: %User{is_admin: true}})` is `true`, everything else `false`, safe to call
  with `nil` — it is just no longer wired to a navbar `<li>`.
- **daisyUI is removed (D-028) and there is no theme toggle, no dark mode, and no inline
  `<script>` in `root.html.heex` at all any more** — the generator's `data-theme`-before-paint
  script is gone along with the theme it toggled. `root.html.heex` is now doctype/head/body and
  `{@inner_content}`, nothing more; its own comment explains why (D-032). If you see
  `Layouts.theme_toggle/1`, `btn`, `input`, `card`, `alert`, `badge`, `menu`, `tabs`, `toggle` or
  `fieldset` classes anywhere in HEEx, they render as **nothing** — grep before adding one. For
  what replaced daisyUI (the sticker design tokens, `ConsensusWeb.Sticker`'s primitives, the
  restyled `CoreComponents`), see the **`design-system`** skill; this skill stays about Phoenix
  mechanics and does not duplicate that content.
- Everything JS goes through `assets/js/app.js` (esbuild bundles `app.js` and `app.css` only —
  no CDN `src`/`href`).

## Core components (`ConsensusWeb.CoreComponents`)

Imported into every template by `html_helpers/0`. The full public surface:

| Component | Notes |
|---|---|
| `<.flash kind={:info\|:error} flash={@flash} />` | rendered via `Layouts.flash_group` |
| `<.button variant="primary" ...>` | `:rest` includes `href navigate patch method download disabled` |
| `<.input field={@form[:x]} type="..." label="..." />` | see types below |
| `<.header>` + `<:subtitle>` + `<:actions>` | |
| `<.table id=... rows=...>` + `<:col :let={r} label="...">` + `<:action>` | the only edited component — the `<table>` sits inside `<div class="overflow-x-auto">` |
| `<.list>` + `<:item title="...">` | |
| `<.icon name="hero-x-mark" class="size-4" />` | heroicons only, never a `Heroicons` module |
| `show/2`, `hide/2` | return `%Phoenix.LiveView.JS{}` |
| `translate_error/1`, `translate_errors/2` | gettext-backed |

`<.input>` `type` is validated against
`~w(checkbox color date datetime-local email file month number password search select tel text
textarea time url week hidden)`. Anything else is a compile-time attr error. Passing `class=` replaces
the default classes entirely — no merge.

## HEEx syntax in 1.8

`{...}` is the interpolation form; `<%= %>` survives only for block constructs.

```heex
{@user.email}                          <!-- body interpolation -->
<div class={["a", @b && "c"]}>         <!-- attribute: curly braces, NOT <%= %> -->
<.icon :if={@kind == :info} name="hero-check" />
<th :for={col <- @col}>{col[:label]}</th>
<.form :let={f} for={@form} phx-submit="save">

<%= if @current_scope do %>            <!-- multi-line block: still <%= %> -->
  ...
<% else %>
  ...
<% end %>
```

- **Attribute values must be `{expr}`.** `class=<%= @x %>` does not compile (see failure modes).
- `{...}` cannot hold a `do`/`end` block. Use `<%= if ... do %>` for those, or `:if` for a single tag.
- `:if` and `:for` are per-tag; there is no `:else`. `:for` + `:if` on the same tag applies `:if` per item.
- A list in a `class` attribute is flattened and falsy entries dropped — that is the idiomatic
  conditional-class form (`core_components.ex` uses it throughout).
- `attr`/`slot` declarations are checked at compile time by the `:phoenix_live_view` compiler
  (`compilers: [:phoenix_live_view] ++ Mix.compilers()` in `mix.exs`), so typos surface at `mix compile`.

## Scopes: `@current_scope`, never `@current_user`

`phx.gen.auth` on 1.8 generates **scopes**. `Consensus.Accounts.Scope` is a struct with one field today:

```elixir
%Consensus.Accounts.Scope{user: %Consensus.Accounts.User{} | nil}
Scope.for_user(%User{}) # => %Scope{user: user}
Scope.for_user(nil)     # => nil          <-- note: nil, not %Scope{user: nil}
```

There is **no `current_user` assign anywhere in this app** — not on the conn, not on the socket.
`fetch_current_scope_for_user/2` (browser pipeline) assigns `:current_scope`; the `on_mount` hooks assign
the same key on the socket. Read the user as `@current_scope.user`.

Because `for_user(nil)` returns `nil`, guard both levels — `socket.assigns.current_scope &&
socket.assigns.current_scope.user` — which is exactly what `UserAuth.on_mount(:require_authenticated, ...)`
does. `Layouts.account_menu/1` does the same, as a HEEx tag modifier rather than a block:
`<details :if={@current_scope && @current_scope.user} ...>`.

`current_user` does not appear as an assign, a conn key, or a parameter anywhere in this app.
`Accounts.login_user_by_magic_link/1` used to take the currently-signed-in user as a second
argument; **it no longer does** — it is arity **1**, and `UserSessionController` calls it as
`Accounts.login_user_by_magic_link(token)`. A two-argument call raises `UndefinedFunctionError`.

Magic-link confirmation (D-015) never refuses — `{:error, :not_confirmed}` no longer exists — and
when it confirms an unconfirmed account that already holds a password it **always discards that
password**, with no exception for a caller already signed in as that user. (Reasoning in the
function's `@doc`: the only session that can exist for an unconfirmed account was minted by
registration, i.e. by the very password under suspicion.) Two web-layer consequences:

- `UserSessionController.magic_link_info/2` matches `%{hashed_password: nil}` on the returned user
  and flashes *"You are logged in. The password that was set on this account has been removed —
  choose a new one under Settings."* instead of the usual "User confirmed successfully."
- `ConsensusWeb.UserLive.Confirmation` computes a `@clears_password?` assign in `mount/3` and renders
  a warning **before** the button is pressed. It is `is_nil(user.confirmed_at) and not
  is_nil(user.hashed_password)` — **no `@current_scope` input**, because there is no signed-in
  exception left to check. The old assign name was `@needs_password_login?`; if you see it, the code
  is stale. Never write UI copy telling someone to "log in with their password first", and never
  offer it as a way to *keep* the password — it is not one.

**Context functions take a scope, not a user.** `Consensus.Activities.update_group/3` binds the
scope's `user_id` and the group's `organizer_id` to the same variable name in the head —
`update_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group, attrs)`
— so a call on someone else's group fails to match any clause and raises `FunctionClauseError`
rather than falling through a branch. Follow that shape for new write functions; see the `elixir`
skill for the one exception (`update_activity/3`/`delete_activity/2`, which re-read the owning
group from the database instead, because an `%Activity{}` carries no organizer field to pattern
match against). `Consensus.Content` — the module this section used to point at — is deleted
(D-027).

## Router: pipelines, scopes, live_sessions

`lib/consensus_web/router.ex`. Current route table, abridged from `mix phx.routes` —
LiveDashboard's `/admin/dashboard/{css,js}-:md5` asset routes and the `GET`/`POST
/live/longpoll` transport fallback are real and omitted here for readability:

```
GET     /health                                ConsensusWeb.HealthController :index
GET     /admin                                 ConsensusWeb.AdminLive.Users :index
GET     /admin/users                           ConsensusWeb.AdminLive.Users :index
GET     /admin/dashboard                       Phoenix.LiveDashboard.PageLive :home
GET     /admin/dashboard/:page                 Phoenix.LiveDashboard.PageLive :page
GET     /admin/dashboard/:node/:page           Phoenix.LiveDashboard.PageLive :page
*       /dev/mailbox                           Plug.Swoosh.MailboxPreview     (dev only)
GET     /users/settings                        ConsensusWeb.UserLive.Settings :edit
GET     /users/settings/confirm-email/:token   ConsensusWeb.UserLive.Settings :confirm_email
POST    /users/update-password                 ConsensusWeb.UserSessionController :update_password
GET     /groups/new                            ConsensusWeb.GroupLive.New :new
GET     /groups/:id/edit                       ConsensusWeb.GroupLive.New :edit
GET     /groups/:id/options                    ConsensusWeb.GroupLive.Options :index
GET     /groups/:id/options/:activity_id       ConsensusWeb.GroupLive.Options :edit_activity
GET     /groups/:id/review                     ConsensusWeb.GroupLive.Review :show
GET     /groups/:id/share                      ConsensusWeb.GroupLive.Share :show
GET     /                                      ConsensusWeb.HomeLive :show
GET     /users/register                        ConsensusWeb.UserLive.Registration :new
GET     /users/log-in                          ConsensusWeb.UserLive.Login :new
GET     /users/log-in/:token                   ConsensusWeb.UserLive.Confirmation :new
POST    /users/log-in                          ConsensusWeb.UserSessionController :create
DELETE  /users/log-out                         ConsensusWeb.UserSessionController :delete
WS      /live/websocket                        Phoenix.LiveView.Socket
```

**`/admin/home-page` is gone** (D-027, the admin-editable home page was deleted) — do not
document it as a route. **`/join/:slug` does not exist yet** either: `docs/plans/creation-flow.md`
names `Consensus.Activities.get_group_by_slug/1` as "the `/join/<slug>` lookup a guest voter
follows", but there is no route or LiveView behind it in `router.ex` today — it is a public,
unauthenticated screen for a future pass, not part of the `:require_authenticated_user`
live_session below. Don't imply a shared join link resolves to a page; it does not yet.

Three `live_session`s, each with its own `on_mount`:

| live_session | on_mount | who |
|---|---|---|
| `:current_user` | `{UserAuth, :mount_current_scope}` | public; `@current_scope` may be `nil` |
| `:require_authenticated_user` | `{UserAuth, :require_authenticated}` | signed-in |
| `:require_admin` | `{UserAuth, :require_admin}` | `%User{is_admin: true}` |

**The organizer's creation wizard lives inside `:require_authenticated_user`, alongside
`/users/settings` — it does not get its own live_session.** `router.ex`'s own comment says why:
all six wizard routes (`GroupLive.New` at `:new`/`:edit`, `GroupLive.Options` at
`:index`/`:edit_activity`, `GroupLive.Review`, `GroupLive.Share`) are steps in one flow — the
design calls them `01 → 02 → 02b → 03 → 04` — and sharing one live_session means moving between
them is a `push_navigate` inside a single connected socket, never a full page reload. Adding a
`live` route for a new wizard step means adding it inside this existing block, not a new
`live_session` — see "Adding an authenticated LiveView route" below for why a second block with
the same name raises.

`UserAuth` also exposes `:require_sudo_mode` for sensitive actions. It calls
`Accounts.sudo_mode?(user, -10)` — **10 minutes**, passed explicitly. Do not read the window off
`Accounts.sudo_mode?/2`, whose own default is `-20`; the hook overrides it.

**Every route is guarded twice on purpose.** The plug pipeline
(`:require_authenticated_user` / `:require_admin_user`) rejects the initial HTTP request; the `on_mount`
hook rejects the LiveView websocket mount. Plugs do **not** run for the socket connection, so the
`on_mount` is not redundant — dropping it is a real auth hole.

`test/consensus_web/router_test.exs` exists to keep that honest: it asserts that every `/admin` route
carries both halves. Because `ConsensusWeb.Router.__routes__/0` does not expose `pipe_through`, the plug
half is asserted against the router *source text* — a comment in the file says so. Removing
`:require_admin_user` would otherwise leave every behavioural test green, since the `on_mount` hook
would silently cover for it.

`live_dashboard/2` declares its own `live_session` internally, so it cannot live inside the `:require_admin`
block; it takes `on_mount: [{ConsensusWeb.UserAuth, :require_admin}]` directly. Note it is mounted in
**all** environments here, admin-only — not behind `:dev_routes` like the generator default.

### Adding an authenticated LiveView route

1. Put the module at `lib/consensus_web/live/<thing>_live.ex` (or `<area>_live/<page>.ex` for a
   namespaced group, matching `UserLive.*` / `AdminLive.*`).
2. `use ConsensusWeb, :live_view`.
3. Add the `live "/path", ThingLive, :action` line **inside the existing `live_session` that already has
   the right `on_mount`** — do not create a new `live_session` per page. Redefining a name raises
   `attempting to redefine live_session :x. live_session routes must be declared in a single named block.`
4. Make sure the enclosing `scope` pipes through the matching plugs
   (`[:browser, :require_authenticated_user]`, plus `:require_admin_user` for `/admin`).
5. Template opens with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.

Navigating between two different `live_session`s always causes a **full page reload**, not a
`live_redirect`. That is by design (the session must be re-established). Keep pages a user pivots between
inside the same `live_session` when you care about the transition.

## Revoking access from an already-mounted LiveView

The non-obvious lesson this repo learned (D-016): **`on_mount` hooks run once, at mount.** A LiveView
holds whatever `%Scope{}` it mounted with for the entire life of the socket. Change a user's role in
the database and the tab they already have open keeps the old role — indefinitely, since a healthy
LiveView never remounts on its own. Before the fix, an admin who had just been demoted could go on
promoting people from an open `/admin/users` tab.

`UserAuth.disconnect_sessions/1` is the lever. It broadcasts `"disconnect"` on
`"users_sessions:" <> Base.url_encode64(token)` for each token you hand it; that topic is written into
the session as `:live_socket_id` by `put_token_in_session/1`, and Phoenix tears down every socket
listening on it. The browser reconnects, mounts again, and the `on_mount` hook re-reads the role.

The contract is that the **context returns the tokens and the caller disconnects them.** `UserAuth` is
web-layer, so `Consensus.Accounts` must not call it:

```elixir
# context — Accounts.set_admin/3 AND Accounts.delete_user/2 both return
# {:ok, {user, tokens_to_disconnect}}. For set_admin/3 the list is [] on promotion and the
# demoted user's session tokens on demotion; for delete_user/2 it is the deleted user's
# session tokens, collected *before* the delete because ON DELETE CASCADE takes them with it.

# LiveView — lib/consensus_web/live/admin_live/users.ex
case Accounts.set_admin(socket.assigns.current_scope, user, make_admin?) do
  {:ok, {updated, tokens_to_disconnect}} ->
    ConsensusWeb.UserAuth.disconnect_sessions(tokens_to_disconnect)
    ...
```

Four rules that come with it:

- **Disconnecting is prompt, not sufficient.** A broadcast can be missed. `Accounts.set_admin/3`
  therefore also re-reads the *actor's* role from the database inside its transaction, so a stale
  socket cannot authorise a write even if the disconnect never landed. Do the same in any new
  privileged context function; never trust `socket.assigns.current_scope` as the authorization input.
- **Every handler that can lose authorization needs an `{:error, :unauthorized}` branch.**
  `AdminLive.Users` answers it with a flash plus `push_navigate(to: ~p"/")`.
- **And an `{:error, :sudo_required}` branch.** Both admin writes require the actor's
  authentication to be fresh (20 minutes) as well as privileged. `AdminLive.Users` routes it
  through a private `require_sudo/2` — flash naming the attempted action, then
  `push_navigate(to: ~p"/users/log-in")`. It also assigns `:sudo?` from
  `Accounts.sudo_mode?/1`, renders `<div id="sudo-notice">` when it is false, and `disabled=`s
  the Promote / Demote / Delete buttons. **That UI disabling is a courtesy, not the guard** —
  `Consensus.Accounts` is the enforcement, and a socket that goes stale after mount still has
  live-looking buttons until something re-renders.
- The same pattern already appears twice in `UserSessionController` — after a password change
  (`update_user_password/2` returns `expired_tokens`) and after a magic-link login. Follow those,
  and note none of them broadcasts from inside the context.

## LiveView lifecycle here

- `mount/3` — runs twice (dead HTTP render, then websocket). `connected?(socket)` gates subscriptions,
  timers, and anything that must not double-fire.
- `handle_params/3` — after mount and on every `push_patch`/`live_patch`. Use it for the `:live_action`
  branch (`UserLive.Settings` uses `:edit` vs `:confirm_email`, dispatched by two `mount/3` clauses).
- `handle_event/3` — `phx-click` / `phx-submit` / `phx-change` / `phx-*`.
- `handle_info/2` — PubSub messages and `Process.send_after` timers.
- `handle_async/3` — completion of `start_async/3`; `assign_async/3` resolves into an `AsyncResult`.
- Navigation: `push_patch/2` (same LiveView, re-runs `handle_params`), `push_navigate/2` (different
  LiveView, same live_session), `redirect/2` (full request).
- Collections use `stream/4` + `stream_insert/4` so the server does not retain the list.
- JS hooks are colocated (`assets/js/app.js` imports `{hooks as colocatedHooks} from
  "phoenix-colocated/consensus"`), so a `<script :type={Phoenix.LiveView.ColocatedHook}>` next to the
  component is the idiomatic place for JS — not a hand-registered hooks map.

## Real-time via PubSub

`{Phoenix.PubSub, name: Consensus.PubSub}` is started in `Consensus.Application`, and
`config/config.exs` sets `pubsub_server: Consensus.PubSub` on the endpoint.

`Consensus.Activities` + `ConsensusWeb.GroupLive.Review` are the working reference implementation
in this repo now that `Consensus.Content` and `HomeLive`'s old home-page subscription are both
gone (D-027) — **contexts own the topic, LiveViews just subscribe**. The topic is
`"activity_group:<id>"`, built by a private `topic/1` in `Consensus.Activities` from the group's
id; the messages are `{:group_updated, %Group{}}`, `{:activity_added, %Activity{}}`,
`{:activity_updated, %Activity{}}` and `{:activities_changed, [%Activity{}]}` (the last one after
a delete-and-renumber or a full reorder, since either can move more than one row at once). Read
`lib/consensus/activities.ex` and `lib/consensus_web/live/group_live/review.ex` rather than
copying from here if you are adding a second real-time surface:

```elixir
# context
def subscribe_group(group_id), do: Phoenix.PubSub.subscribe(Consensus.PubSub, topic(group_id))
# ...after a successful write:
broadcast(group.id, {:group_updated, group})
```

```elixir
# LiveView — GroupLive.Review, so a friend adding options while the organizer is on this
# screen shows up without a refresh (CLAUDE.md product invariant 4)
def mount(%{"id" => id}, _session, socket) do
  group = Activities.get_group!(socket.assigns.current_scope, id)
  if connected?(socket), do: Activities.subscribe_group(group.id)
  {:ok, assign_group(socket, group)}
end

def handle_info({:group_updated, _group}, socket), do: {:noreply, reload(socket)}
def handle_info({:activity_added, _activity}, socket), do: {:noreply, reload(socket)}
def handle_info({:activity_updated, _activity}, socket), do: {:noreply, reload(socket)}
def handle_info({:activities_changed, _activities}, socket), do: {:noreply, reload(socket)}
```

Note `Review` re-reads from storage on every message (`reload/1` calls `get_group!/2` again)
rather than patching the broadcast payload into the socket directly — the same function also
handles a rejected client-side reorder snapping back to the saved order, so one code path covers
both "a friend changed something" and "my own optimistic UI guess was wrong". `HomeLive` follows
the same PubSub-subscribe shape for its list of groups (see its own moduledoc for the exact
topics it joins across all of a signed-in organizer's active groups).

Do not call `Phoenix.PubSub.broadcast/3` from a LiveView. Do not subscribe outside `connected?/1` — the
dead render would leak a subscription in the HTTP process.

For per-user or per-session fan-out, scope the topic string off `current_scope` (that is why the `Scope`
moduledoc mentions pubsub) rather than broadcasting globally and filtering in `handle_info`.

## Async work: `start_async`/`handle_async`, and never inline in `handle_event`

`ConsensusWeb.GroupLive.Options` (design frames `02`/`02b`) is the load-bearing example of this
pattern in the app: a LiveView process is one process handling one user's whole page, so a
network call made inline inside a `handle_event/3` callback — `Consensus.LinkPreview.fetch/1`
included — blocks that process, and with it the user's entire page, for as long as the remote
server takes. **A LiveView must never make a network call inline in `handle_event`.**

`start_async/3` spawns a `Task` and returns immediately; the result arrives later as a
`handle_async/3` message. The name you give it is a key, and `Options` keys by *activity id*
deliberately — pasting a second link cannot clobber the in-flight fetch for a different row,
because `start_async/3`'s own contract is "if there is an in-flight task with the same name, the
later `start_async` wins", and two different activities never share a name:

```elixir
# lib/consensus_web/live/group_live/options.ex
defp add_link_activity(socket, url, host) do
  attrs = %{name: host, source_url: url}

  case Activities.add_activity(socket.assigns.current_scope, socket.assigns.group, attrs) do
    {:ok, activity} ->
      socket =
        socket
        |> insert_activity(activity)
        |> mark_fetching(activity.id)
        |> start_async({:link_preview, activity.id, host}, fn -> LinkPreview.fetch(url) end)

      {:noreply, socket}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "Could not add that option.")}
  end
end

@impl true
def handle_async({:link_preview, activity_id, provisional_name}, {:ok, {:ok, preview}}, socket) do
  {:noreply, apply_preview(socket, activity_id, preview, provisional_name)}
end

def handle_async({:link_preview, activity_id, _provisional_name}, {:ok, {:error, _reason}}, socket) do
  {:noreply, mark_fetch_failed(socket, activity_id)}
end

def handle_async({:link_preview, activity_id, _provisional_name}, {:exit, _reason}, socket) do
  {:noreply, mark_fetch_failed(socket, activity_id)}
end
```

Three things to copy along with the shape:

- **The row is created immediately, with a provisional name, and enriched later.** The activity
  exists and renders before the fetch resolves — `@fetching`/`@fetch_failed` are plain (non-DB)
  socket `MapSet`s the template reads to show "fetching details…" / "couldn't read that page",
  because the schema has no "fetch in progress" column and shouldn't grow one for a rendering
  concern.
- **`handle_async/3` always has three clauses for a network call: success, a returned `{:error,
  _}`, and `{:exit, _reason}`.** `Task` delivers `{:ok, task_result}` when the function returned
  normally (even if `task_result` is itself `{:error, _}` — `Consensus.LinkPreview.fetch/1` never
  raises, so that is the ordinary failure shape) and `{:exit, reason}` when the function crashed.
  Missing the `{:exit, _}` clause is a `handle_async/3` that silently ignores a Task crash instead
  of updating `@fetch_failed`.
- **Refetch reuses the same mechanism with a different key** (`{:refetch, activity_id}`, no
  provisional-name tracking) so a deliberate "Refetch" click on the edit screen and the original
  paste-triggered fetch cannot be confused with each other even for the same activity.

## LiveView streams, and the `reset: true` reload idiom

`GroupLive.Options` and `GroupLive.Review` both use `stream/4` for the activity pool — a `phx-update="stream"`
container the server does not retain the list for, per the LiveView lifecycle note above.
`Review` is the one to read for the `reset: true` idiom: its drag-to-reorder hook reorders the DOM
**optimistically**, client-side, before the server has confirmed anything, and the `"reorder"`
event handler always ends the same way regardless of whether `Consensus.Activities.reorder_activities/3`
accepted or refused the new order:

```elixir
def handle_event("reorder", %{"ids" => ids}, socket) do
  case parse_ids(ids) do
    {:ok, ordered_ids} ->
      Activities.reorder_activities(socket.assigns.current_scope, socket.assigns.group, ordered_ids)

    :error ->
      :ok
  end

  # The hook already reordered the DOM optimistically. Whatever just happened — accepted or
  # refused — reloading from storage is what makes the stored order the truth: on success this
  # reflects the new order, and on refusal it snaps the DOM back to the order that was actually
  # saved, undoing the client's guess.
  {:noreply, reload(socket)}
end

defp assign_group(socket, group) do
  socket
  |> assign(:group, group)
  |> stream(:activities, group.activities, reset: true)
end
```

Without `reset: true`, `stream/4` only *adds* entries it has not seen — it will not remove or
reorder what the client already rendered, so a rejected reorder (or a delete-triggered renumber,
which `Options` handles the same way via its own `reload_and_reset/2`) would leave the DOM
showing the client's wrong guess forever. `reset: true` throws the stream's rendered state away
and replaces it wholesale with what was just read from storage — the correct move whenever a
write might have changed more than one row's identity or order, as opposed to `stream_insert/3`,
which is for updating or inserting exactly one known item without disturbing the rest (`Options`
uses that for a single-activity save).

## Verified routes `~p`

`use Phoenix.VerifiedRoutes` comes in via `html_helpers/0`, `controller/0`, and `:verified_routes`
(`ConsensusWeb.UserAuth` uses the last). Available in LiveViews, components, controllers, `ConnCase`
tests, and `UserAuth`.

```elixir
~p"/admin/users"
~p"/users/log-in/#{token}"
~p"/admin/users?#{[page: 2]}"
url(~p"/admin")            # absolute, uses the endpoint config
```

A path with no matching route is a **warning**, not an error — but `mix precommit` runs
`compile --warnings-as-errors`, so it fails the build anyway. Never string-concat a route.

## Testing LiveViews

`test/consensus_web/live/user_live/login_test.exs` is the canonical example. Boilerplate:

```elixir
defmodule ConsensusWeb.ThingLiveTest do
  use ConsensusWeb.ConnCase
  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  setup :register_and_log_in_user    # gives %{conn: conn, user: user, scope: scope}

  test "renders", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/thing")
    assert html =~ "Thing"
    assert lv |> element("#save") |> render_click() =~ "Saved"
  end
end
```

**On `async: true`:** the test suite runs one case at a time regardless of the tag —
`test/test_helper.exs` calls `ExUnit.start(max_cases: 1)` (D-033) — so `async: true` still buys
the Ecto sandbox's per-case isolation (own connection, own transaction, rolled back at exit) but
no longer buys concurrent wall-clock time. Full mechanism in the `sqlite` skill; the practical
upshot for a web test is that `async: true` is still the right default to reach for, it just does
not need defending against a "SQLite can't do concurrent writers" objection any more than it
already couldn't. `test/consensus_web/live/group_live/new_test.exs`,
`test/consensus_web/live/group_live/options_test.exs`, `test/consensus_web/live/home_live_test.exs`
and `test/consensus_web/journey_test.exs` are all `async: true` LiveView tests that do real
database work and pass. `router_test.exs` (a bare `use ExUnit.Case, async: true`, no database),
`error_html_test.exs` and `error_json_test.exs` are the other `async: true` web tests.
Most LiveView tests, plus `user_auth_test.exs` and `user_session_controller_test.exs`, still carry
no `async:` flag, which is generator inheritance rather than a decision.
`health_controller_test.exs` is the one web test **pinned** `async: false`, and its comment
explains why: it runs `ALTER TABLE … RENAME` to prove `/health` can fail, and SQLite needs an
exclusive lock on the whole file for DDL, which collides with a shared (non-async) connection's
read transaction independent of `max_cases`. **Any test you write that issues DDL needs
`async: false`** — ordinary inserts and updates do not. Details in the `elixir` and `sqlite`
skills.

**`render_async/1,2` is how a LiveView test waits on a `start_async` task**, and
`test/consensus_web/live/group_live/options_test.exs` ("adding a link" · "creates the row
immediately with a provisional name, then fills it in asynchronously") is the worked example —
it blocks the stub on a message from the test process specifically so the "row exists
immediately, with a provisional name" assertions cannot race the async fill-in, then releases it
and calls `render_async/1`:

```elixir
LinkPreviewStub.stub(fn requested_url, _opts ->
  send(test_pid, {:fetch_started, self()})
  receive do: (:continue -> {:ok, %{status: 200, headers: [...], body: html_preview(), url: requested_url}})
end)

view |> form("#add-option-form", add_option: %{query: url}) |> render_submit()
assert_receive {:fetch_started, task_pid}, 1000

# the row exists, with a provisional name, before the fetch has resolved
assert [created] = Activities.get_group!(scope, group.id).activities
assert created.name == @link_host
refute created.metadata_fetched_at

send(task_pid, :continue)
html = render_async(view)

assert html =~ "Sushi Enya"
```

`render_async/2` defaults to ExUnit's `assert_receive_timeout`, **100 ms** — too short for
anything that genuinely waits — so pass an explicit timeout when a case is slow rather than
assuming the default covers it.

**The trap that actually cost time here: a stub installed in the test process is invisible from
inside the `Task` a `start_async` spawns, unless the stub goes looking for it.**
`Consensus.LinkPreview.fetch/1` calls out to whatever `config :consensus, Consensus.LinkPreview,
fetcher:` names — `Consensus.LinkPreviewStub` in test (`test/support/link_preview_stub.ex`) — and
that Task runs in a *different* process from the one that called `stub/1` or `stub_html/2`.
`Task.async`/`start_async` copies the spawning process's `:"$callers"` chain into the new
process's dictionary specifically so this kind of thing can be found, and the stub walks it —
`Enum.find_value([self() | Process.get(:"$callers", [])], ...)` — the same mechanism Mox's
`allow/3` automates, done by hand because this project carries no Mox. Forgetting this and
storing the stub function keyed only on `self()` would make every LiveView test that pastes a
link fail with `{:error, :not_configured}`, for a reason that has nothing to do with the LiveView
under test — context tests would still pass, because there `fetch/1` runs in the test process
itself.

`ConsensusWeb.ConnCase` provides `log_in_user/3` and `register_and_log_in_user/1` (which also accepts a
`:token_authenticated_at` context key for sudo-mode tests). Fixtures in `Consensus.AccountsFixtures`:
`user_fixture/1`, `unconfirmed_user_fixture/1`, **`admin_fixture/1`**, `user_scope_fixture/0,1`,
**`admin_scope_fixture/1`**, **`stale_scope/1`**, `set_password/1`,
`override_token_authenticated_at/2`, `generate_user_magic_link_token/1`, `offset_user_token/3`.
`stale_scope/1` takes a `%Scope{}` or a `%User{}` and returns a scope authenticated a day ago —
use it to drive the `{:error, :sudo_required}` path and the `#sudo-notice` rendering rather than
hand-rolling a timestamp. Use `admin_fixture/1` for `/admin` route
tests rather than hand-rolling the role. Note it writes `is_admin` via `User.admin_changeset/2`
directly, *not* through `Accounts.set_admin/3` — that function requires an admin actor, which is a
chicken-and-egg problem for the first admin. The fixture carries a comment saying so.
`Consensus.ActivitiesFixtures` (`test/support/fixtures/activities_fixtures.ex`) is the wizard
screens' equivalent: `group_fixture/2` takes a `%Scope{}`, `activity_fixture/2` takes a `%Group{}`.

**`test/consensus_web/journey_test.exs` is the end-to-end acceptance test for the creation side,
and it is deliberately one test, not a suite of small ones.** It drives a single organizer
through the whole flow in one `conn` and then a *second*, fresh one: sign up → create a group →
add options (both typed and by pasting a link) → edit an option → review and publish → get the
share link → log out → log back in with a new session and confirm everything survived. Every
screen already has its own file covering its own branches; this test exists to catch what only
shows up *between* screens — a wizard step that `push_navigate`s somewhere that does not exist,
a value that renders but was never actually written, a draft that cannot be resumed after the
websocket is thrown away and rebuilt from scratch. Run it whenever a change touches more than one
screen in the wizard; a change confined to one screen's own file is usually covered by that
screen's own test.

Three web tests are not LiveView tests and are easy to miss.
`test/consensus_web/router_test.exs` walks `ConsensusWeb.Router.__routes__/0` and the router source to
prove every `/admin` route keeps both guards.
`test/consensus_web/controllers/health_controller_test.exs` (`async: false`, deliberately — see
above) asserts `GET /health`
returns `200 "ok"`, that it returns `503 "migrations pending"` and `503 "database unavailable"` on
the two failure paths, that the route's `pipe_through` is `[]` (contrasted against `/`'s
`[:browser]`, so the empty list is a real assertion and not a `route_info` artefact), and that the
response sets no cookies and no `content-security-policy` / `x-frame-options` headers. It then
reaches outside the app for two config assertions: **`config/prod.exs` is evaluated**, not grepped
— `Config.Reader.read!("config/prod.exs", env: :prod, target: :host)`, then
`assert "/health" in force_ssl[:exclude][:paths]` — while **`fly.toml` is read as text** and must
contain `[[http_service.checks]]` and `path = '/health'`. Editing either file can therefore fail a
*web* test; that is deliberate, since the two must agree or the machine never reports healthy.
`test/consensus_web/user_auth_test.exs` has `describe`
blocks for `log_in_user/3`, `logout_user/1`, `fetch_current_scope_for_user/2`, `disconnect_sessions/1`,
`require_authenticated_user/2`, `require_admin_user/2`, and the `:mount_current_scope`,
`:require_authenticated`, `:require_sudo_mode` and `:require_admin` `on_mount` hooks. Anything you add
to `user_auth.ex` belongs there, not in a page's own test file.

Verified `Phoenix.LiveViewTest` surface: `live/2,3`, `live_isolated/3`, `element/2,3`, `has_element?/2,3`,
`form/3`, `render_click/1,2,3`, `render_submit/*`, `render_change/*`, `render_hook/3`, `render_async/1,2`,
`follow_redirect/2,3`, `assert_patch/1,2,3`, `assert_patched/2`, `assert_redirect/*`, `assert_redirected/2`,
`open_browser/1,2`.

Notes that bite:

- `follow_redirect/3` is a **macro** and rebinds `conn`; use it as
  `form(lv, "#f", user: %{...}) |> render_submit() |> follow_redirect(conn, ~p"/path")`.
- Guard tests: `assert {:error, {:redirect, %{to: ~p"/users/log-in"}}} = live(conn, ~p"/admin")`.
- `element/2` must match exactly one node or it raises. Prefer stable `id=` over class selectors.
- `config/test.exs` sets `enable_expensive_runtime_checks: true` — dodgy attr/slot usage fails in test
  even when it renders fine in dev.
- Use `mix test path/to/file.exs:LINE` to run a single test.

## Common failure modes

**`KeyError: key :current_scope not found`** (raised at render, from `Layouts.app` or the template).
The route is not inside a `live_session` that runs a `UserAuth` `on_mount` hook. Fix by moving the
`live` line into `:current_user`, `:require_authenticated_user`, or `:require_admin` — **not** by
assigning `current_scope` yourself in `mount/3`.

**`warning: no route path for ConsensusWeb.Router matches "/foo"`.** Typo in a `~p`, or the route lives
in a `scope` with a prefix you forgot (`/admin`). Compilation still succeeds, so this is easy to miss —
`mix precommit` turns it into a failure. Confirm with `mix phx.routes | grep foo`.

**`invalid attribute value after `=`. Expected either a value between quotes (such as "value" or 'value')
or an Elixir expression between curly braces (such as `{expr}`)`.** You wrote `class=<%= @x %>` or
`id=<%= @id %>`. Attributes take `{...}`: `class={@x}`.

**`TokenMissingError: ... missing terminator: end ... unclosed delimiter`** pointing into a `~H`
sigil. You put a `do` block inside `{...}` — e.g. `{if @x do}...{end}`. `{}` holds a single expression.
Use `<%= if @x do %>...<% end %>`, or `:if={@x}` on the tag.

**`KeyError: key :missing not found in: ...`** while rendering. A template reads an assign that
`mount/3` never set. Set it unconditionally in `mount/3` (`assign_new/3` for values a parent may
supply), or use `assigns[:missing]` when genuinely optional.

**`attempting to define live_session :x inside :y. live_session definitions cannot be nested.`**
You wrapped a `live_session` around `live_dashboard/2` (it declares its own) or nested two blocks. Give
the inner one its own sibling `scope` with the same `pipe_through`.

**`attempting to redefine live_session :x. live_session routes must be declared in a single named block.`**
Two blocks share a name. One block per name, all its routes inside it.

**LiveView test hangs / `render_async` returns the loading state.** `render_async/2` defaults to ExUnit's
`assert_receive_timeout` (**100 ms**). Pass an explicit timeout — `render_async(lv, 2_000)` — or await the
specific task. `render_async` covers `assign_async`, `stream_async` and `start_async`. If it still fails,
the async fun probably needs a DB connection that the SQL sandbox never allowed it: pass the caller with
`Ecto.Adapters.SQL.Sandbox.allow/3`, or fetch the data in `mount/3`.

**`ConsensusWeb.SomeLive.__live__/0 is undefined (module ... is not available or is yet to be defined)`.**
A `live` route names a module that is not on disk. Every module `router.ex` names does exist today, so
this means you added the route ahead of the module. It is emitted from `Router.__checks__/0` and
`mix precommit` turns it into a build failure — land the route and the module in one change.

## Commands

```bash
export PATH="/opt/homebrew/bin:$PATH"

mix phx.routes                     # full route table (compiles first)
mix compile --warnings-as-errors   # what precommit enforces
mix format --check-formatted
export MIX_TEST_PARTITION=7        # own SQLite file; safe alongside another agent
mix test
mix test test/consensus_web/live/user_live/login_test.exs:12
mix precommit                      # compile --warnings-as-errors, deps.unlock --unused, format, test
mix phx.server                     # dev; magic-link emails at /dev/mailbox
```

`config/test.exs:12` interpolates `MIX_TEST_PARTITION` into the database filename, so exporting
it gives you a private `consensus_test<N>.db`. Delete those files when you finish.
**`mix precommit` inherits the variable like every other mix invocation** — an alias runs its
tasks in the same OS process — so export your digit once and run the gate normally; there is no
reason to serialize behind another agent. Verified 2026-08-08: with every `consensus_test*` file
deleted, `MIX_TEST_PARTITION=6 mix precommit` created only `consensus_test6.db{,-shm,-wal}` and
never touched `consensus_test.db`.

**`mix precommit` is not CI.** CI (`.github/workflows/ci.yml`, job `test`, Elixir 1.20.3 / OTP
29.0.5, `MIX_ENV=test`) runs `mix deps.get --check-locked`, `mix deps.unlock --check-unused`,
`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. `precommit`
skips `--check-locked`, and its `format` / `deps.unlock --unused` steps **rewrite** files and
exit 0 where CI asserts and exits 1; commit whatever they changed.

**The separate `docker` job does not just build the image — it boots it**, and two of its
assertions are about the web layer, so they are yours to keep green:

- **A real LiveView websocket upgrade must answer 101.** The step curls
  `/live/websocket?vsn=2.0.0` with `Origin: https://$PHX_HOST` and
  `x-forwarded-proto: https`, where `PHX_HOST` is read out of `fly.toml`. A 403 means
  `check_origin` (true by default in prod) rejected the endpoint's own hostname. That failure
  is otherwise invisible: every page here is a LiveView, so the app would be completely inert
  while `GET /` still answered 200 from the dead render and `/health` still answered 200.
- **`GET /health` must answer 200 under `Host: $PHX_HOST`, and 503 once the schema is broken.**
  Not under `Host: 127.0.0.1` — `config/prod.exs` excludes that host from `force_ssl` anyway,
  so it proves nothing about the `paths: ["/health"]` exclusion.

It also asserts the bootstrap admin is seeded and, in a second step, boots twice on one volume
to migrate a populated database. Because `mix test` never starts a release, that job is the only
place any of it runs. Full transcription and a runnable local reproduction are in the `elixir`
skill under "Reproducing CI locally, completely" — `docker build` alone is not it.

`mix phx.gen.live` is available and emits 1.8-shaped code (scopes, `Layouts.app`), but it also generates a
context and migration — review before accepting, and follow the repo rule that non-trivial features get a
plan in `docs/plans/<feature>.md` first.
