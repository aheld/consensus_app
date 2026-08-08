defmodule ConsensusWeb.UserSessionController do
  use ConsensusWeb, :controller

  alias Consensus.Accounts
  alias ConsensusWeb.UserAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    # Decided from the state *before* the login consumes the token. Asking afterwards
    # whether `hashed_password` is nil cannot tell "a password was just discarded" from
    # "this account never had one" — and D-017 makes the latter the permanent end state
    # of every account the app reclaims, so the warning fired on every routine magic-link
    # login and told the person something untrue. A warning that cries wolf on every
    # login is worse than none: the one time it matters, it reads as noise.
    clears_password? = clears_password?(token)

    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, magic_link_info(clears_password?, info))
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # username-or-email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"password" => password} = user_params
    # The log-in form posts `login`; the registration form and the settings
    # password form post `email`. Both are accepted.
    login = user_params["login"] || user_params["email"] || ""

    if user = Accounts.get_user_by_login_and_password(login, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the
      # username or email is registered.
      conn
      |> put_flash(:error, "Invalid email/username or password")
      |> put_flash(:login, String.slice(login, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # `login_user_by_magic_link/1` discards the password whenever it confirms an account
  # that had one. Say so, or the person's next log-in attempt fails for no visible
  # reason.
  # Deliberately the same predicate, on the same user, that
  # `ConsensusWeb.UserLive.Confirmation.clears_password?/1` uses to warn *before* the
  # button is pressed. Keep the two in step: the page and the flash contradicting each
  # other inside one flow is how this bug was found.
  defp clears_password?(token) do
    case Accounts.get_user_by_magic_link_token(token) do
      %Accounts.User{confirmed_at: nil, hashed_password: hash} -> not is_nil(hash)
      _ -> false
    end
  end

  defp magic_link_info(true, _info) do
    "You are logged in. The password that was set on this account has been removed — " <>
      "choose a new one under Settings."
  end

  defp magic_link_info(false, info), do: info

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user

    # The generator writes this as `true = Accounts.sudo_mode?(user)`, which is a correct
    # guarantee expressed as a crash: a session that fell out of sudo between rendering
    # the form and posting it gets a 500 rather than being told what happened. The
    # guarantee is what matters and it is unchanged — the password is only ever updated
    # inside this branch — but the failure is now a redirect the person can act on.
    if Accounts.sudo_mode?(user) do
      {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> create(params, "Password updated successfully!")
    else
      conn
      |> put_flash(:error, "For security, log in again to change your password.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
