---
name: phoenix
description: Phoenix 1.8 and LiveView 1.2 conventions for the Consensus app — layouts (Layouts.app plus root.html.heex, no app.html.heex), core components, HEEx syntax ({} vs <%= %>, :if/:for), the LiveView lifecycle (mount/handle_params/handle_event/handle_info), live_session and on_mount hooks, Phoenix 1.8 scopes (Consensus.Accounts.Scope and @current_scope, never current_user), revoking a mounted LiveView's access with UserAuth.disconnect_sessions/1, verified routes ~p, PubSub for real-time updates, the router pipelines in lib/consensus_web/router.ex, and testing with Phoenix.LiveViewTest. Use this when adding or editing anything under lib/consensus_web/ — a LiveView, a route, a component, a template, a LiveView test — or when debugging a missing current_scope assign, a ~p route warning, a HEEx compile error, or a LiveView test that fails on async assigns.
---

# Phoenix 1.8 + LiveView in this repo

`mix phx.new consensus --database sqlite3` → `mix phx.gen.auth Accounts User users` →
`mix phx.gen.release --docker`. Phoenix 1.8.9, phoenix_live_view 1.2.8, Elixir 1.20.3, OTP 29.

A pristine copy of that generator output lives at
`/private/tmp/claude-501/-Users-aheld-Projects-consensus-app/ae875c1c-a7e9-4615-8dd8-8949816c8f19/scratchpad/reference/consensus`.
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
  layouts.ex                               # Layouts.app/1, flash_group/1, theme_toggle/1
  layouts/root.html.heex                   # the ONLY .heex layout file
  core_components.ex                       # flash, button, input, header, table, list, icon, ...
lib/consensus_web/live/home_live.ex        # public "/" — reads Content, subscribes to PubSub
lib/consensus_web/live/admin_live/         # users.ex, home_page.ex
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

All seven LiveViews now exist on disk: `live/home_live.ex`, `live/admin_live/{users,home_page}.ex`,
`live/user_live/{login,registration,confirmation,settings}.ex`. `mix compile --warnings-as-errors`
and `mix format --check-formatted` both exit 0 (verified 2026-08-08). The app is still being written
concurrently, so `ls lib/consensus_web/live/` before assuming a module's shape.

## Layouts: 1.8 has no `app.html.heex`

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

Rules that fall out of that:

- `Layouts` is already aliased by `html_helpers/0` in `lib/consensus_web.ex`. Never alias it again.
- `attr :flash, :map, required: true` — omitting `flash=` is a compile-time error.
- `attr :current_scope, :map, default: nil` — optional to the component, but pass it: `root.html.heex`
  reads `@current_scope` for the nav, and the app's own header will need it.
- `<.flash_group>` lives in `Layouts` and is rendered *inside* `Layouts.app`. Never call it anywhere else.
- **The account menu lives in `Layouts.app/1`, not in `root.html.heex`.** The generator put it in the
  root layout; this app moved it out (there is a comment in `root.html.heex` saying so) so LiveViews and
  controller-rendered pages get the same nav. If you are adding a nav item, edit `layouts.ex`.
- `Layouts.admin?/1` is a local helper on the `Scope` struct — `admin?(%Scope{user: %User{is_admin: true}})`
  is `true`, everything else `false`. It drives `<li :if={admin?(@current_scope)}>` for the Admin link.
  Use it rather than reaching into `@current_scope.user.is_admin` in a template, which blows up on `nil`.
- The theme toggle (`Layouts.theme_toggle/1`) pairs with the inline `<script>` in the `<head>` of
  `root.html.heex` that sets `data-theme` before paint. Leave that script alone.
- `root.html.heex` is the only place an inline `<script>` is allowed. Everything else goes through
  `assets/js/app.js` (esbuild bundles `app.js` and `app.css` only — no CDN `src`/`href`).

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
does. In `layouts.ex` the account menu does the same: `<%= if @current_scope && @current_scope.user do %>`.

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

**Context functions take a scope, not a user.** `Consensus.Content.update_home_page/2` pattern-matches
`%Scope{user: %User{is_admin: true}}` in the head, so a non-admin caller raises `FunctionClauseError`
rather than falling through a branch. Follow that shape for new write functions.

## Router: pipelines, scopes, live_sessions

`lib/consensus_web/router.ex`. Current route table, abridged from `mix phx.routes` —
LiveDashboard's `/admin/dashboard/{css,js}-:md5` asset routes and the `GET`/`POST
/live/longpoll` transport fallback are real and omitted here for readability:

```
GET     /health                                ConsensusWeb.HealthController :index
GET     /admin                                 ConsensusWeb.AdminLive.Users :index
GET     /admin/users                           ConsensusWeb.AdminLive.Users :index
GET     /admin/home-page                       ConsensusWeb.AdminLive.HomePage :edit
GET     /admin/dashboard                       Phoenix.LiveDashboard.PageLive :home
GET     /admin/dashboard/:page                 Phoenix.LiveDashboard.PageLive :page
GET     /admin/dashboard/:node/:page           Phoenix.LiveDashboard.PageLive :page
*       /dev/mailbox                           Plug.Swoosh.MailboxPreview     (dev only)
GET     /users/settings                        ConsensusWeb.UserLive.Settings :edit
GET     /users/settings/confirm-email/:token   ConsensusWeb.UserLive.Settings :confirm_email
POST    /users/update-password                 ConsensusWeb.UserSessionController :update_password
GET     /                                      ConsensusWeb.HomeLive :show
GET     /users/register                        ConsensusWeb.UserLive.Registration :new
GET     /users/log-in                          ConsensusWeb.UserLive.Login :new
GET     /users/log-in/:token                   ConsensusWeb.UserLive.Confirmation :new
POST    /users/log-in                          ConsensusWeb.UserSessionController :create
DELETE  /users/log-out                         ConsensusWeb.UserSessionController :delete
WS      /live/websocket                        Phoenix.LiveView.Socket
```

Three `live_session`s, each with its own `on_mount`:

| live_session | on_mount | who |
|---|---|---|
| `:current_user` | `{UserAuth, :mount_current_scope}` | public; `@current_scope` may be `nil` |
| `:require_authenticated_user` | `{UserAuth, :require_authenticated}` | signed-in |
| `:require_admin` | `{UserAuth, :require_admin}` | `%User{is_admin: true}` |

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

`Consensus.Content` + `ConsensusWeb.HomeLive` are the working reference implementation in this repo —
**contexts own the topic, LiveViews just subscribe**. The topic is `@topic "content:home_page"`, private
to `Consensus.Content`; the message is `{:home_page_updated, %HomePage{}}`. Read those two files rather
than copying from here if you are adding a second real-time surface:

```elixir
# context
def subscribe_home_page, do: Phoenix.PubSub.subscribe(Consensus.PubSub, "content:home_page")
# ...after a successful write:
Phoenix.PubSub.broadcast(Consensus.PubSub, @topic, {:home_page_updated, home_page})
```

```elixir
# LiveView
def mount(_params, _session, socket) do
  if connected?(socket), do: Consensus.Content.subscribe_home_page()
  {:ok, assign(socket, home_page: Consensus.Content.get_home_page())}
end

def handle_info({:home_page_updated, home_page}, socket) do
  {:noreply, assign(socket, :home_page, home_page)}
end
```

Do not call `Phoenix.PubSub.broadcast/3` from a LiveView. Do not subscribe outside `connected?/1` — the
dead render would leak a subscription in the HTTP process.

For per-user or per-session fan-out, scope the topic string off `current_scope` (that is why the `Scope`
moduledoc mentions pubsub) rather than broadcasting globally and filtering in `handle_info`.

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

**On `async: true`:** there is no blanket ban in this repo, despite the stock "not recommended for
other databases" moduledoc in `conn_case.ex`. The Ecto sandbox gives each async case its own
transaction (`shared: not tags[:async]`) and `config/test.exs` sets `busy_timeout: 5_000` so real
write contention waits instead of failing. `test/consensus/content_test.exs` runs `async: true`
against the database and passes; the full suite is 0 failures (323 tests on 2026-08-08, and
climbing — re-run rather than quoting the number). Three
web tests run `async: true` — `router_test.exs` (a bare `use ExUnit.Case, async: true`,
no database), `error_html_test.exs` and `error_json_test.exs`.
Every LiveView test, plus `user_auth_test.exs` and `user_session_controller_test.exs`, carries
no `async:` flag, which is generator inheritance rather than a decision.
`health_controller_test.exs` is the one web test **pinned** `async: false`, and its comment
explains why: it runs `ALTER TABLE … RENAME` to prove `/health` can fail, SQLite takes an
exclusive lock on the whole file for DDL, and under `async: true` that lock makes unrelated
tests die with `** (Exqlite.Error) Database busy`. **Any test you write that issues DDL needs
`async: false`** — ordinary inserts and updates do not. Details in the `elixir` and `sqlite`
skills.

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
