defmodule ConsensusWeb.UserAuth do
  use ConsensusWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Consensus.Accounts
  alias Consensus.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_consensus_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  # Session keys `renew_session/2` carries across a log-in or a log-out. See the long
  # comment on that function: these are a guest's ballot receipts, not credentials.
  @participant_key_prefix "participant_token:"

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Records where log-in should land, from a caller-supplied path.

  `log_in_user/3` already honours `:user_return_to`, but until D-045 the only thing that
  ever wrote it was `maybe_store_return_to/1`, which runs in a plug on a **GET** request.
  A LiveView that wants to send someone away to re-authenticate has no conn to write, so
  `ConsensusWeb.AdminLive.Users` flashed "you will come back to Admin → Users" and the app
  then delivered them to `/users/settings` (`signed_in_path/1` for an already-signed-in
  conn). This is the missing half: the LiveView puts the destination in the log-in URL,
  `ConsensusWeb.UserLive.Login` carries it through the form, and
  `ConsensusWeb.UserSessionController` calls this before `log_in_user/3`.

  **The path is validated, and it must stay validated.** This writes a value that a
  successful authentication then redirects to, so an unchecked `return_to` on this
  endpoint is an open redirect on the log-in page — the single most valuable place in an
  app to have one, because the victim arrives already convinced. `ConsensusWeb.CurrentPath.safe_return_to/1`
  is the same check the footer's standing-page links use: a single-slash absolute path
  only, so anything carrying a scheme or a host (`https://evil.example`), and both
  protocol-relative spellings (`//evil.example`, `/\\evil.example`) are refused. Anything
  refused is dropped silently and log-in falls back to `signed_in_path/1` — a rejected
  destination must never become an error message that teaches an attacker the filter's
  shape.
  """
  def store_return_to(conn, path) do
    case ConsensusWeb.CurrentPath.safe_return_to(path) do
      nil -> conn
      safe -> put_session(conn, :user_return_to, safe)
    end
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      ConsensusWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  # The generator's comment above is exactly the hook this app needs, and not taking it
  # cost a voter their ballot. `ConsensusWeb.JoinAuth.participant_session_key/1` writes
  # `"participant_token:<group_id>"` — a guest's *only* proof that they joined a vote and
  # cast it, since a guest has no account (product invariant 1). Signing in wiped every one
  # of them: measured, a guest who voted and then tapped the header's "Create your own →"
  # (rendered on every `/join` screen) and logged in was returned to `/join/:slug` as a
  # brand-new visitor, offered the ballot again, and `JoinController.resolve_guest/3` — whose
  # only dedupe *is* that session key — minted a second participant row. Guests carry
  # `user_id: nil`, so the partial unique index does not catch it, and the tally counted one
  # person twice.
  #
  # These keys are ballot receipts, not credentials: they authorize nothing an attacker
  # wants, the ballot they unlock is already locked by `Consensus.Voting` (D-036), and they
  # name no account. Session fixation is a reason to drop the *identity* in the session, not
  # the guest's record of what they did before acquiring one. Preserved on log-out for the
  # same reason — logging out of an account must not orphan the vote a guest cast in the
  # same browser.
  defp renew_session(conn, _user) do
    delete_csrf_token()

    participant_tokens =
      conn
      |> get_session()
      |> Enum.filter(fn {key, _value} ->
        is_binary(key) and String.starts_with?(key, @participant_key_prefix)
      end)

    conn = conn |> configure_session(renew: true) |> clear_session()

    Enum.reduce(participant_tokens, conn, fn {key, value}, conn ->
      put_session(conn, key, value)
    end)
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      ConsensusWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:require_admin` - Same as `:require_authenticated`, and additionally
      requires the user to hold the admin role. Non-admins are sent to the
      home page rather than the login page: they are already signed in, so
      offering them the login form would be a dead end.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule ConsensusWeb.PageLive do
        use ConsensusWeb, :live_view

        on_mount {ConsensusWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{ConsensusWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %Accounts.User{is_admin: true}} ->
        {:cont, socket}

      %Scope{user: %Accounts.User{}} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You do not have access to that page.")
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}

      _ ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, params, session, socket),
    do: on_mount({:require_sudo_mode, nil}, params, session, socket)

  # `{:require_sudo_mode, path}` is the same hook with the D-045 return trip on the end.
  # A hook runs in a LiveView, so it has no conn to write `:user_return_to` into — which
  # is exactly why `store_return_to/2` exists and why the destination has to travel in the
  # log-in URL. The base path is supplied by the caller rather than read off the request
  # because `on_mount` is handed no URI: it is the screen's *own* route, written in its own
  # module, not anything a visitor can influence, and `store_return_to/2` re-validates it on
  # the way back in regardless.
  #
  # Without it, a person bounced out of `/users/settings` for re-authentication logs in and
  # is delivered to `signed_in_path/1` — `/users/settings` for a signed-in conn, which is
  # right by luck for this one screen and would be wrong for the next one to use the hook.
  #
  # **The caller's path is a base, not the whole answer, because a LiveView can serve more
  # than one route.** `ConsensusWeb.UserLive.Settings` serves `/users/settings` *and*
  # `/users/settings/confirm-email/:token`, and the second is the one that matters here:
  # that link is emailed and therefore read later, so exceeding the 10-minute window is the
  # ordinary case, not the edge. With a static return path the bounce dropped the token on
  # the floor and re-auth landed on the settings form with the old address still in it and
  # nothing on screen saying the click had done nothing. `on_mount/4` *is* handed `params`,
  # so the token is right there; it is appended when present, and `store_return_to/2`'s
  # validation sees the finished path either way.
  def on_mount({:require_sudo_mode, return_to}, params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: log_in_path(sudo_return_to(return_to, params)))

      {:halt, socket}
    end
  end

  # `/users/settings` + a `"token"` param is `/users/settings/confirm-email/:token`. The
  # base path is a compile-time `~p` literal from the LiveView; the token is a URL segment
  # and is encoded as one by `~p`.
  defp sudo_return_to("/users/settings", %{"token" => token}) when is_binary(token),
    do: ~p"/users/settings/confirm-email/#{token}"

  defp sudo_return_to(return_to, _params), do: return_to

  defp log_in_path(nil), do: ~p"/users/log-in"
  defp log_in_path(path), do: ~p"/users/log-in?#{[return_to: path]}"

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Plug for routes that require the user to hold the admin role.

  Must run after `require_authenticated_user/2`. Defence in depth: every admin route
  also goes through the `:require_admin` `on_mount` hook, so an admin LiveView is
  guarded on the initial HTTP request *and* on the websocket mount.
  """
  def require_admin_user(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{is_admin: true}} ->
        conn

      %Scope{user: %Accounts.User{}} ->
        conn
        |> put_flash(:error, "You do not have access to that page.")
        |> redirect(to: ~p"/")
        |> halt()

      _ ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/users/log-in")
        |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
