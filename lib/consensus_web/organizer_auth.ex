defmodule ConsensusWeb.OrganizerAuth do
  @moduledoc """
  Plugs and `on_mount` hooks for the organizer with no account (D-058).

  The organizer-side sibling of `ConsensusWeb.JoinAuth`, and the same pattern on the
  other side of the share link: a server-minted token, written by something that can set
  a cookie, resolved by an `on_mount` hook. Two deliberate differences from the guest's
  token (plan `docs/plans/accountless-organizer.md` §1):

    * **One identity per browser, not one per group.** A single token resolves to one
      `Consensus.Activities.AnonymousOrganizer` that owns every session this browser
      started.
    * **Its own long-lived signed cookie, not the Phoenix session.** The session cookie
      has no `max_age`, so it dies when the browser quits — before the post-deadline
      return trip that matters most. The cookie's name comes from
      `config :consensus, :organizer_cookie` (`__Host-consensus_organizer` in prod).
      `fetch_organizer_token/2` mirrors it into the session key `"organizer_token"` (and
      re-issues it, so its 90 days are an idle window) on every `:browser` request, exactly as `UserAuth.ensure_user_token/1` mirrors the
      remember-me cookie, because a LiveView reads only the session at connect. Being
      outside the session is also why `UserAuth.renew_session/2` never touches it.

  ## Where the anonymous identity is visible

  **Only inside `live_session :organizer`** (the wizard) does `@current_scope` become an
  anonymous `%Scope{}` — `:require_organizer` assigns it there so every wizard screen has
  one code path for both kinds of owner. Everywhere else `@current_scope` stays `nil` or
  a user scope, because two dozen templates read its truthiness as "signed in";
  `:mount_organizer_scope` hands the anonymous identity to `/` under a separate
  `@organizer_scope` assign instead. Nothing here touches `ConsensusWeb.UserAuth`.

  ## Minting happens on `GET /groups/new` only

  A LiveView cannot write a cookie, so `ensure_organizer_identity/2` mints the row and the
  cookie before `GroupLive.New` mounts. The other six wizard routes only *resolve*: minting
  there would insert a row for every crawler probing enumerable `/groups/:id/*` URLs, on
  the single SQLite writer the ballot burst also needs (invariant 17).
  """

  use ConsensusWeb, :verified_routes

  import Plug.Conn

  require Logger

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Activities
  alias Consensus.Activities.AnonymousOrganizer
  alias ConsensusWeb.GroupLive

  @cookie Application.compile_env!(:consensus, :organizer_cookie)
  @max_age_in_days 90
  @cookie_options [
    sign: true,
    max_age: @max_age_in_days * 24 * 60 * 60,
    http_only: true,
    same_site: "Lax",
    # `__Host-` cookies are refused by the browser unless they are Secure, so the
    # prefix and the flag travel together: prod has both, dev and test (no TLS) neither.
    secure: String.starts_with?(@cookie, "__Host-")
  ]

  @session_key "organizer_token"

  @cookies_blocked "This browser didn't keep the cookie Consensus needs to remember your " <>
                     "session. Allow cookies for this site and try again."
  @log_in_to_reach "If this session is yours, log in to reach it."
  @busy "Consensus is busy — try again in a moment."

  @doc "The organizer cookie's name for this environment."
  def cookie_name, do: @cookie

  @doc "The options the organizer cookie is written with."
  def cookie_options, do: @cookie_options

  @doc """
  The Phoenix session key the organizer token is mirrored into.

  `UserAuth.log_in_user/4`'s claim (plan §6) reads the cookie, not this key; the key
  exists only because a LiveView sees the session and nothing else.
  """
  def session_key, do: @session_key

  @doc """
  The PubSub topic every LiveView socket holding this organizer token listens on.

  Derived from the token's SHA-256 digest — the value the row already stores — rather than
  from the row id, so `fetch_organizer_token/2` can write it into the session as
  `"live_socket_id"` on every `:browser` request without a database read. That is what
  makes it reach *every* wizard tab, not only one that came in through the mint: a tab
  reached via `/` → a group card after the session cookie died never passes
  `GET /groups/new`. A successful claim, which holds the raw token from the cookie,
  broadcasts `"disconnect"` here, so a tab still mounted with the anonymous scope stops
  writing to sessions an account now owns (plan §6.3).
  """
  def live_socket_id(raw_token) when is_binary(raw_token) do
    digest = :crypto.hash(:sha256, raw_token)
    "organizer_sessions:" <> Base.url_encode64(digest, padding: false)
  end

  @doc """
  The raw organizer token from the verified signed cookie, or `nil`.

  For `UserAuth.log_in_user/4`'s claim: the cookie, never the session copy — a session
  can be planted by a sibling subdomain, the `__Host-` cookie cannot (see
  `fetch_organizer_token/2`). Safe to call on a conn whose cookies were already fetched.
  """
  def read_organizer_cookie(conn) do
    case fetch_cookies(conn, signed: [@cookie]).cookies[@cookie] do
      token when is_binary(token) -> token
      _none -> nil
    end
  end

  @doc """
  Forgets this browser's organizer identity: expires the cookie (with the options it was
  written with, or the browser keeps it) and drops the session's copy and its anonymous
  `live_socket_id`. Called once a claim has settled the token for good.
  """
  def delete_organizer_cookie(conn) do
    conn
    |> delete_resp_cookie(@cookie, @cookie_options)
    |> drop_organizer_session()
  end

  ## Plugs

  @doc """
  Mirrors the signed organizer cookie into the session, when there is one, and slides it.

  Free: it verifies a signature and copies a binary, with no database access, so it is
  safe on every `:browser` request.

  **The session strictly mirrors the cookie.** An absent or tampered cookie removes any
  organizer token the session still holds, along with its anonymous disconnect topic.
  The session cookie carries no `__Host-` prefix, so a sibling subdomain can plant one —
  a validly signed session minted for the attacker's own browser — and if a session copy
  outlived its cookie, every session the victim then started would belong to the
  attacker's identity. A session therefore carries an organizer token only when this
  same request carried the verified cookie. A verified one does three things:

    * puts the token in the session, where a LiveView can read it;
    * re-issues the cookie with a fresh `max_age`, so the browser's 90 days slide with use
      the way the row's `last_seen_at` does (plan §1). Written once at mint, it would
      expire 90 days after an active organizer's *first* visit, stranding every session
      the still-live row owns. Sliding a dead token is harmless — the resolver still
      refuses it, and `GET /groups/new` replaces it;
    * when no user is signed in, puts the token's `live_socket_id/1` topic in the session,
      so every anonymous socket — whichever route it came in on — is one the claim's
      disconnect can reach. A signed-in user's session already carries their own topic,
      which this never overwrites.
  """
  def fetch_organizer_token(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])

    case conn.cookies[@cookie] do
      token when is_binary(token) ->
        conn
        |> put_resp_cookie(@cookie, token, @cookie_options)
        |> put_session(@session_key, token)
        |> put_organizer_socket_id(token)

      _none ->
        drop_organizer_session(conn)
    end
  end

  defp put_organizer_socket_id(conn, token) do
    case conn.assigns[:current_scope] do
      %Scope{user: %User{}} -> conn
      _no_user -> put_session(conn, :live_socket_id, live_socket_id(token))
    end
  end

  # Deletes only what is there, so a cookieless request that never had an identity does
  # not rewrite its session cookie on every page. A signed-in user's own `users_sessions:`
  # topic is left alone — only an `organizer_sessions:` one belongs to this module.
  defp drop_organizer_session(conn) do
    conn =
      if get_session(conn, @session_key),
        do: delete_session(conn, @session_key),
        else: conn

    case get_session(conn, :live_socket_id) do
      "organizer_sessions:" <> _ -> delete_session(conn, :live_socket_id)
      _other -> conn
    end
  end

  @doc """
  Gives a visitor with no account an organizer identity — on `GET /groups/new` only.

  A signed-in user needs none, and a browser whose verified cookie still resolves already
  has one (the resolver touched it; `fetch_organizer_token/2` already slid its cookie and
  put its `live_socket_id` in the session). It is resolved from the cookie, never the
  session — see `fetch_organizer_token/2`. Otherwise this mints a row, writes the signed cookie,
  puts the token and its `live_socket_id` in the session, and assigns
  `:current_scope` on the conn. That last assign is not cosmetic:
  `UserAuth.on_mount(:mount_current_scope, ...)` uses `assign_new`, which copies the
  conn's `nil` into the dead render, so without it a first-ever visit would render step 1
  with no scope at all.
  """
  def ensure_organizer_identity(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %User{}} ->
        conn

      _no_user ->
        # The verified cookie, never the session: ownership comes from `__Host-` alone.
        case Activities.get_anonymous_organizer_by_token(conn.cookies[@cookie]) do
          %AnonymousOrganizer{} ->
            conn

          nil ->
            mint_identity(conn)
        end
    end
  end

  defp mint_identity(conn) do
    {raw_token, organizer} = Activities.mint_anonymous_organizer()

    conn
    |> put_resp_cookie(@cookie, raw_token, @cookie_options)
    |> put_session(@session_key, raw_token)
    |> put_session(:live_socket_id, live_socket_id(raw_token))
    |> assign(:current_scope, Scope.for_anonymous_organizer(organizer))
  rescue
    # The mint is an insert on the single SQLite writer the ballot burst also needs
    # (invariant 17). Refused, it must not 500 the front door of the product: send the
    # visitor back to `/` with something to do. Nothing was written, so the retry mints
    # cleanly.
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.warning("[organizer] mint refused: database busy (#{Exception.message(error)})")

      conn
      |> Phoenix.Controller.put_flash(:error, @busy)
      |> Phoenix.Controller.redirect(to: ~p"/")
      |> halt()
  end

  ## on_mount hooks

  @doc """
  `on_mount` hooks for the organizer's identity.

    * `:require_organizer` — `live_session :organizer` (the wizard), chained **after**
      `{ConsensusWeb.UserAuth, :mount_current_scope}`. A user scope passes through
      untouched. Otherwise the session's organizer token is resolved and `@current_scope`
      is replaced (`assign/3`, never `assign_new`) with the anonymous scope. When neither
      identity resolves, `/groups/new` halts to `/` with a "cookies needed" flash when the
      session never carried an identity at all, and otherwise — a token or user token that
      went stale under an open tab, after a log-out or a claim elsewhere — redirects to
      `/groups/new` itself, whose plugs find the account or mint afresh; and every
      `/groups/:id/*` route halts to the log-in form carrying `return_to`, which is the
      bounce an account holder had before D-058. It never sends a stranger to the group's
      `/join` page: that would turn sequential group ids into a slug-enumeration oracle.
      A connected anonymous mount also subscribes to the token's `live_socket_id/1` topic
      and redirects when a claim broadcasts there (plan §6.3), whatever its session cookie
      said when the socket connected.

    * `:mount_organizer_scope` — read-only, for `/`. Assigns `@organizer_scope` to the
      anonymous scope, or `nil` when a user is signed in or nothing resolves. It never
      mints and never changes `@current_scope`.
  """
  def on_mount(:require_organizer, params, session, socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: %User{}} ->
        {:cont, socket}

      _no_user ->
        case resolve(session) do
          %Scope{} = scope ->
            {:cont,
             socket
             |> Phoenix.Component.assign(:current_scope, scope)
             |> leave_when_claimed(session[@session_key], params)}

          nil ->
            {:halt, bounce(socket, params, session)}
        end
    end
  end

  def on_mount(:mount_organizer_scope, _params, session, socket) do
    organizer_scope =
      case socket.assigns[:current_scope] do
        %Scope{user: %User{}} -> nil
        _no_user -> resolve(session)
      end

    {:cont, Phoenix.Component.assign(socket, :organizer_scope, organizer_scope)}
  end

  # Every connected anonymous wizard tab listens for the claim itself, rather than relying
  # only on the transport's `live_socket_id`. That id is read from the session cookie as
  # it stood when the websocket connected, and `fetch_organizer_token/2` puts the topic
  # there on every anonymous request — but a cookie another tab rewrote in between (a
  # log-in elsewhere, an expired user token) can leave a mounted tab outside it, still
  # holding the anonymous scope its head-matched writes are authorized by. So the process
  # subscribes to the same topic and, on the claim's `"disconnect"`, redirects to the
  # route it is on: the full request re-runs the plugs, which find the account that now
  # owns the session (same browser) or bounce to log-in (anywhere else).
  defp leave_when_claimed(socket, raw_token, params) do
    if Phoenix.LiveView.connected?(socket) do
      topic = live_socket_id(raw_token)
      :ok = Phoenix.PubSub.subscribe(Consensus.PubSub, topic)
      to = wizard_path(socket.view, socket.assigns[:live_action], params)
      to = if to in [nil, :new], do: ~p"/groups/new", else: to

      Phoenix.LiveView.attach_hook(socket, :organizer_claimed, :handle_info, fn
        %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, socket ->
          {:halt, Phoenix.LiveView.redirect(socket, to: to)}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp resolve(session) do
    session[@session_key]
    |> Activities.get_anonymous_organizer_by_token()
    |> Scope.for_anonymous_organizer()
  end

  # `on_mount` is handed no URI, so the route is read off the view and its live action
  # (both assigned before any hook runs) plus the path params.
  defp bounce(socket, params, session) do
    case wizard_path(socket.view, socket.assigns[:live_action], params) do
      :new ->
        if carried_identity?(session) do
          # The identity went stale under an open tab — a log-out or a claim in another
          # tab disconnected it, and the rejoin replays the static session signed at dead
          # render. A full request re-runs the plugs, which find the account or mint afresh.
          Phoenix.LiveView.redirect(socket, to: ~p"/groups/new")
        else
          socket
          |> Phoenix.LiveView.put_flash(:error, @cookies_blocked)
          |> Phoenix.LiveView.redirect(to: ~p"/")
        end

      path ->
        socket
        |> Phoenix.LiveView.put_flash(:error, @log_in_to_reach)
        |> Phoenix.LiveView.redirect(to: log_in_path(path))
    end
  end

  # Whether the session ever held an identity, resolvable or not. Only one that held
  # neither means the mint's cookie never came back: the connected mount reads the session
  # signed at dead render, which already carries the minted token even when the browser
  # refused the cookie, so a stale token is not evidence of blocked cookies.
  defp carried_identity?(session),
    do: is_binary(session[@session_key]) or is_binary(session["user_token"])

  # The path the visitor asked for, rebuilt from the route — every one a `~p` literal, so
  # the `return_to` it becomes is this module's, not the visitor's. `store_return_to/2`
  # re-validates it on the way back in regardless.
  defp wizard_path(GroupLive.New, :new, _params), do: :new
  defp wizard_path(GroupLive.New, :edit, %{"id" => id}), do: ~p"/groups/#{id}/edit"
  defp wizard_path(GroupLive.Options, :index, %{"id" => id}), do: ~p"/groups/#{id}/options"

  defp wizard_path(GroupLive.Options, :edit_activity, %{"id" => id, "activity_id" => aid}),
    do: ~p"/groups/#{id}/options/#{aid}"

  defp wizard_path(GroupLive.Review, :show, %{"id" => id}), do: ~p"/groups/#{id}/review"
  defp wizard_path(GroupLive.Share, :show, %{"id" => id}), do: ~p"/groups/#{id}/share"
  defp wizard_path(GroupLive.Results, :show, %{"id" => id}), do: ~p"/groups/#{id}/results"
  defp wizard_path(_view, _action, _params), do: nil

  defp log_in_path(nil), do: ~p"/users/log-in"
  defp log_in_path(path), do: ~p"/users/log-in?#{[return_to: path]}"
end
