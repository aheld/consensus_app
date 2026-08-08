defmodule Consensus.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Consensus.Repo

  alias Consensus.Accounts.{Scope, User, UserToken, UserNotifier}

  # How long an authentication stays "fresh". `sudo_mode?/2` reads it as its default
  # window and `sudo_mode_expires_at/1` reads it as an instant, so it lives here rather
  # than as a literal in either.
  @sudo_mode_minutes 20

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a user by username.

  The `users.username` column is declared `COLLATE NOCASE`, so the lookup is
  case-insensitive.

  ## Examples

      iex> get_user_by_username("aheld")
      %User{}

      iex> get_user_by_username("nobody")
      nil

  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Gets a user by either their username or their email address.

  Used by the log-in form, which accepts whichever one the person remembers.
  """
  def get_user_by_login(login) when is_binary(login) do
    if String.contains?(login, "@") do
      get_user_by_email(login)
    else
      get_user_by_username(login)
    end
  end

  @doc """
  Gets a user by username-or-email and password.

  ## Examples

      iex> get_user_by_login_and_password("aheld", "correct_password")
      %User{}

      iex> get_user_by_login_and_password("aheld", "invalid_password")
      nil

  """
  def get_user_by_login_and_password(login, password)
      when is_binary(login) and is_binary(password) do
    user = get_user_by_login(login)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, or `nil`.

  Prefer this over `get_user!/1` when the id came from a client — an admin action
  should answer "no such user", not crash the LiveView.
  """
  # SQLite integers are 64-bit; anything outside that range makes exqlite raise instead
  # of simply finding nothing, so it is rejected here rather than at the driver.
  @max_row_id 9_223_372_036_854_775_807
  def get_user(id) when is_integer(id) and id > 0 and id <= @max_row_id, do: Repo.get(User, id)
  def get_user(id) when is_integer(id), do: nil

  @doc """
  Lists every user, oldest first.

  Only reachable from the admin area — see `ConsensusWeb.UserAuth.require_admin_user/2`.
  """
  def list_users do
    Repo.all(from(u in User, order_by: [asc: u.inserted_at, asc: u.id]))
  end

  @doc """
  Returns every user holding the admin role, oldest first.
  """
  def list_admins do
    Repo.all(
      from(u in User, where: u.is_admin == true, order_by: [asc: u.inserted_at, asc: u.id])
    )
  end

  @doc """
  Returns the number of users holding the admin role.
  """
  def count_admins do
    Repo.aggregate(from(u in User, where: u.is_admin == true), :count)
  end

  @doc """
  Returns the total number of user accounts.
  """
  def count_users do
    Repo.aggregate(User, :count)
  end

  @doc """
  Grants or revokes the admin role, on behalf of an administrator.

  Returns `{:ok, {user, tokens_to_disconnect}}`. `tokens_to_disconnect` is the demoted
  user's live session tokens; the caller must hand them to
  `ConsensusWeb.UserAuth.disconnect_sessions/1`, because a LiveView that is already
  mounted holds the scope it was mounted with and would otherwise keep its admin
  powers until it happened to reconnect.

  Four things are checked inside one transaction:

    * the *actor* still holds the admin role — re-read from the database, because an
      admin demoted a moment ago must not be able to act on a page they still have open;
    * the actor is still in **sudo mode** — see `ensure_actor_in_sudo_mode/1`. Granting
      the admin role is an account-takeover-grade action, so it is held to the same
      freshness bar as renaming your own account;
    * the target still exists;
    * demoting would not remove the last admin, which would lock everybody out.

  ## Examples

      iex> set_admin(admin_scope, user, true)
      {:ok, {%User{is_admin: true}, []}}

      iex> set_admin(admin_scope, only_admin, false)
      {:error, :last_admin}

      iex> set_admin(stale_admin_scope, user, true)
      {:error, :sudo_required}

      iex> set_admin(member_scope, user, true)
      {:error, :unauthorized}

  """
  def set_admin(%Scope{user: %User{} = actor}, %User{} = user, is_admin)
      when is_boolean(is_admin) do
    Repo.transact(fn ->
      with :ok <- ensure_actor_is_admin(actor.id),
           :ok <- ensure_actor_in_sudo_mode(actor),
           {:ok, target} <- fetch_user(user.id),
           :ok <- ensure_not_last_admin(target, is_admin) do
        apply_admin_change(target, is_admin)
      end
    end)
    |> audit(if(is_admin, do: "grant_admin", else: "revoke_admin"), actor, user)
  rescue
    # SQLite serialises writes. Under real contention exqlite raises rather than
    # returning a tuple, and a busy database is not a bug the operator can fix by
    # reading a stack trace.
    error in Exqlite.Error -> {:error, {:database_busy, Exception.message(error)}}
  end

  def set_admin(scope, %User{}, is_admin)
      when is_boolean(is_admin) and (is_nil(scope) or is_struct(scope, Scope)),
      do: {:error, :unauthorized}

  defp ensure_actor_is_admin(actor_id) do
    case Repo.get(User, actor_id) do
      %User{is_admin: true} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp ensure_actor_in_sudo_mode(%User{} = actor) do
    if sudo_mode?(actor), do: :ok, else: {:error, :sudo_required}
  end

  defp fetch_user(id) do
    case Repo.get(User, id) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_not_last_admin(%User{is_admin: true}, false) do
    if count_admins() <= 1, do: {:error, :last_admin}, else: :ok
  end

  defp ensure_not_last_admin(_user, _is_admin), do: :ok

  defp apply_admin_change(%User{is_admin: is_admin} = user, is_admin), do: {:ok, {user, []}}

  defp apply_admin_change(user, is_admin) do
    with {:ok, updated} <- user |> User.admin_changeset(%{is_admin: is_admin}) |> Repo.update() do
      tokens =
        if is_admin, do: [], else: Repo.all_by(UserToken, user_id: user.id, context: "session")

      {:ok, {updated, tokens}}
    end
  end

  @doc """
  Deletes a user account, on behalf of an administrator.

  This is the app's account-recovery lever. Without a mail provider configured there is
  no magic link, so someone who forgets their password has no self-service way back in
  and — because `users.email` is unique — cannot re-register either. An admin deleting
  the account frees the address. See docs/decisions.md.

  Refuses to delete an administrator (demote them first, which is a deliberate second
  step) and refuses to let an admin delete themselves. The actor is re-read and held to
  sudo mode, exactly as in `set_admin/3` — destroying an account is the other half of
  the same authority. Session tokens go with the row via `ON DELETE CASCADE`; SQLite
  enforces it, `PRAGMA foreign_keys` is on.

  **Deleting an organizer destroys every activity group they organized, and every option
  inside those groups.** `activity_groups.organizer_id` is `ON DELETE CASCADE`, so the
  cascade runs two levels deep and there is no undo. That is a real change in what this
  function costs: when it was written the only other row pointing at a user was the
  home page's `updated_by_id`, which was merely nulled. It is still the right cascade —
  a group with no organizer has nobody who can publish, cancel or complete it — but the
  admin screen's confirmation must keep saying so, and this is the reason the sudo-mode
  requirement on this function is not ceremony.

  Returns `{:ok, {user, tokens_to_disconnect}}`, the same shape as `set_admin/3` and for
  the same reason: the rows are gone, but the *sockets* holding them are not. The
  caller must hand the tokens to `ConsensusWeb.UserAuth.disconnect_sessions/1` or the
  deleted person keeps a live LiveView on a scope that no longer has an account behind
  it. The tokens are collected before the delete, since the cascade takes them with it.

  ## Examples

      iex> delete_user(admin_scope, member)
      {:ok, {%User{}, [%UserToken{}]}}

      iex> delete_user(admin_scope, another_admin)
      {:error, :is_admin}

      iex> delete_user(stale_admin_scope, member)
      {:error, :sudo_required}

  """
  def delete_user(%Scope{user: %User{} = actor}, %User{} = user) do
    Repo.transact(fn ->
      with :ok <- ensure_actor_is_admin(actor.id),
           :ok <- ensure_actor_in_sudo_mode(actor),
           {:ok, target} <- fetch_user(user.id),
           :ok <- refuse_self_deletion(actor.id, target),
           :ok <- refuse_admin_deletion(target) do
        tokens_to_disconnect = Repo.all_by(UserToken, user_id: target.id, context: "session")

        with {:ok, deleted} <- Repo.delete(target), do: {:ok, {deleted, tokens_to_disconnect}}
      end
    end)
    |> audit("delete_user", actor, user)
  rescue
    # As in `set_admin/3`: SQLite raises rather than returning a tuple when a write
    # cannot get the lock, and that is not something to crash a LiveView over.
    error in Exqlite.Error -> {:error, {:database_busy, Exception.message(error)}}
  end

  def delete_user(scope, %User{}) when is_nil(scope) or is_struct(scope, Scope),
    do: {:error, :unauthorized}

  defp refuse_self_deletion(actor_id, %User{id: actor_id}), do: {:error, :self}
  defp refuse_self_deletion(_actor_id, _user), do: :ok

  defp refuse_admin_deletion(%User{is_admin: true}), do: {:error, :is_admin}
  defp refuse_admin_deletion(_user), do: :ok

  # The audit trail for the two writes that grant or destroy authority.
  #
  # This deployment has one machine, no external audit sink and no undo, so this log
  # line is the only record of who promoted or deleted whom. Refusals are logged too:
  # a burst of `REFUSED (:unauthorized)` is what an attempt to use a revoked session
  # looks like, and it is worth as much as the successes.
  #
  # Ids come first because usernames can be changed afterwards. Nothing derived from a
  # password is ever logged. Returns its input unchanged — auditing must never alter
  # what the caller sees.
  defp audit(result, action, %User{} = actor, %User{} = target) do
    who =
      "actor_id=#{actor.id} actor=#{inspect(actor.username)} " <>
        "target_id=#{target.id} target=#{inspect(target.username)}"

    case result do
      {:ok, _} -> Logger.info("[audit] #{action} #{who}")
      {:error, reason} -> Logger.warning("[audit] #{action} REFUSED #{inspect(reason)} #{who}")
    end

    result
  end

  ## User registration

  @doc """
  Registers a user with an email, a username and a password.

  ## Examples

      iex> register_user(%{email: ..., username: ..., password: ...})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking registration changes.

  See `Consensus.Accounts.User.registration_changeset/3` for supported options.

  ## Examples

      iex> change_user_registration(%User{})
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  @doc """
  Creates a user directly, bypassing the public registration form.

  Used by `Consensus.Seeds` to provision the bootstrap administrator. Accepts
  `:is_admin` and `:confirmed_at`, which `register_user/1` deliberately does not.
  """
  def create_user(attrs, opts \\ []) do
    %User{}
    |> User.registration_changeset(attrs, opts)
    |> Ecto.Changeset.cast(attrs, [:is_admin, :confirmed_at])
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further than
  #{@sudo_mode_minutes} minutes ago. The limit can be given as second argument in
  minutes (negative, i.e. an offset into the past).

  Two things depend on this: `UserLive.Settings` via
  `ConsensusWeb.UserAuth.on_mount(:require_sudo_mode, ...)`, and the two admin writes
  that grant or destroy authority — `set_admin/3` and `delete_user/2`.
  """
  def sudo_mode?(user, minutes \\ -@sudo_mode_minutes)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Consensus.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the username.

  See `Consensus.Accounts.User.username_changeset/3` for supported options.
  """
  def change_user_username(user, attrs \\ %{}, opts \\ []) do
    User.username_changeset(user, attrs, opts)
  end

  @doc """
  Updates the username.

  Unlike an email change, this needs no confirmation round-trip: the username is an
  identifier inside the app, not proof of controlling an inbox.
  """
  def update_user_username(%User{} = user, attrs) do
    user
    |> User.username_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Consensus.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set. This app
     registers users *with* a password, so — unlike the generated default — this case
     is reachable, and it is the credential-pre-stuffing case described in the
     "Mixing magic link and password registration" section of `mix help phx.gen.auth`:
     an attacker registers someone else's address with a password of their choosing
     and waits for the real owner to confirm it.

     The password on an unconfirmed account is **always discarded**, with no exception
     for a caller who is already signed in as that user. In this app the only way a
     session exists for an unconfirmed account is registration itself, so such a
     session is minted by the very password that is under suspicion — honouring it
     would narrow the attack to session fixation rather than close it. Whoever
     controls the inbox is the rightful owner: the account is confirmed and logged in
     with its password discarded, the squatter's credential stops working, and the
     owner sets a new password from Settings (they are in sudo mode, having just
     authenticated). That is the "Forgot your password?"-like workflow the same doc
     section calls for, and it is why this can return a user with
     `hashed_password: nil` — callers should say so.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # The credential-pre-stuffing case: never trust a password set before the
      # address was proven. See the moduledoc above and `mix help phx.gen.auth`.
      {%User{confirmed_at: nil, hashed_password: hash} = user, _token}
      when not is_nil(hash) ->
        user
        |> User.confirm_and_clear_password_changeset()
        |> update_user_and_delete_all_tokens()

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
