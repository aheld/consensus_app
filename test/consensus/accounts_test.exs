defmodule Consensus.AccountsTest do
  use Consensus.DataCase

  alias Consensus.Accounts

  import Consensus.AccountsFixtures
  alias Consensus.Accounts.{Scope, User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email uniqueness ignoring case for username-shaped input" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(valid_user_attributes(email: email))
      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "requires a username" do
      {:error, changeset} = Accounts.register_user(%{email: unique_user_email()})
      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates username format and length" do
      {:error, changeset} = Accounts.register_user(valid_user_attributes(username: "no spaces"))

      assert "may only contain letters, numbers, underscores and hyphens" in errors_on(changeset).username

      {:error, changeset} = Accounts.register_user(valid_user_attributes(username: "ab"))
      assert "should be at least 3 character(s)" in errors_on(changeset).username

      {:error, changeset} =
        Accounts.register_user(valid_user_attributes(username: String.duplicate("a", 31)))

      assert "should be at most 30 character(s)" in errors_on(changeset).username
    end

    test "validates username uniqueness, ignoring case" do
      %{username: username} = user_fixture()

      {:error, changeset} = Accounts.register_user(valid_user_attributes(username: username))
      assert "has already been taken" in errors_on(changeset).username

      {:error, changeset} =
        Accounts.register_user(valid_user_attributes(username: String.upcase(username)))

      assert "has already been taken" in errors_on(changeset).username
    end

    test "requires a password of at least 12 characters" do
      {:error, changeset} = Accounts.register_user(%{email: unique_user_email()})
      assert %{password: ["can't be blank"]} = errors_on(changeset)

      {:error, changeset} = Accounts.register_user(valid_user_attributes(password: "short"))
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "registers users with a hashed password, unconfirmed and not an admin" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
      refute user.is_admin
    end

    test "cannot be used to grant the admin role" do
      {:ok, user} = Accounts.register_user(valid_user_attributes(%{is_admin: true}))
      refute user.is_admin
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms an unconfirmed user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "confirms an unconfirmed user who has no password" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: nil])
      user = Accounts.get_user!(user.id)
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, _}} = Accounts.login_user_by_magic_link(encoded_token)
      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "confirms a password-holding account from an anonymous session, discarding the password" do
      # The credential-pre-stuffing case from the "Mixing magic link and password
      # registration" section of `mix help phx.gen.auth`. Whoever can read the inbox
      # owns the account; a password set before confirmation is not trusted.
      user = unconfirmed_user_fixture()
      assert user.hashed_password
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, _}} = Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
      assert is_nil(user.hashed_password)
      refute Accounts.get_user_by_login_and_password(user.username, valid_user_password())
    end

    test "an attacker's planted password stops working once the owner confirms" do
      # 1. Attacker registers the victim's address with a password of their choosing.
      {:ok, victim_account} =
        Accounts.register_user(%{
          email: "victim@example.com",
          username: "victim",
          password: "attackers password"
        })

      assert Accounts.get_user_by_login_and_password("victim", "attackers password")

      # 2. The victim, who controls the inbox, uses a magic link.
      {encoded_token, _} = generate_user_magic_link_token(victim_account)
      assert {:ok, {user, _}} = Accounts.login_user_by_magic_link(encoded_token)

      # 3. The account is theirs, and the attacker's credential is dead.
      assert user.confirmed_at
      refute Accounts.get_user_by_login_and_password("victim", "attackers password")
      refute Accounts.get_user_by_login_and_password("victim@example.com", "attackers password")
    end

    test "discards the password even for a session already signed in as that user" do
      # There is no signed-in exception, and there deliberately isn't one: the only
      # way a session exists for an *unconfirmed* account is registration itself, so
      # such a session was minted by the very password under suspicion. Honouring it
      # would narrow credential pre-stuffing to session fixation instead of closing it.
      user = unconfirmed_user_fixture()
      session_token = Accounts.generate_user_session_token(user)
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, expired_tokens}} = Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
      assert is_nil(user.hashed_password)
      refute Accounts.get_user_by_login_and_password(user.username, valid_user_password())

      # and that registration session is expired and handed back for disconnection
      assert Enum.any?(expired_tokens, &(&1.context == "session"))
      refute Accounts.get_user_by_session_token(session_token)
    end

    test "is arity 1 — there is no session argument that can preserve a password" do
      refute function_exported?(Accounts, :login_user_by_magic_link, 2)
      assert function_exported?(Accounts, :login_user_by_magic_link, 1)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "get_user_by_login/1 and get_user_by_login_and_password/2" do
    setup do
      %{user: user_fixture(%{username: "findme"})}
    end

    test "finds a user by username, ignoring case", %{user: user} do
      assert Accounts.get_user_by_login("findme").id == user.id
      assert Accounts.get_user_by_login("FINDME").id == user.id
    end

    test "finds a user by email", %{user: user} do
      assert Accounts.get_user_by_login(user.email).id == user.id
    end

    test "returns nil for an unknown login" do
      refute Accounts.get_user_by_login("nobody")
      refute Accounts.get_user_by_login("nobody@example.com")
      refute Accounts.get_user_by_login("")
    end

    test "authenticates with either identifier", %{user: user} do
      assert Accounts.get_user_by_login_and_password("findme", valid_user_password()).id ==
               user.id

      assert Accounts.get_user_by_login_and_password(user.email, valid_user_password()).id ==
               user.id
    end

    test "rejects a wrong password", %{user: user} do
      refute Accounts.get_user_by_login_and_password("findme", "wrong password here")
      refute Accounts.get_user_by_login_and_password(user.email, "wrong password here")
    end
  end

  describe "list_users/0 and count_admins/0" do
    test "lists users oldest first and counts admins" do
      first = user_fixture()
      second = admin_fixture()

      assert Enum.map(Accounts.list_users(), & &1.id) == [first.id, second.id]
      assert Accounts.count_admins() == 1
    end
  end

  describe "set_admin/3" do
    setup do
      %{actor: admin_scope_fixture(%{username: "theactor"})}
    end

    test "grants the role", %{actor: actor} do
      user = user_fixture()
      refute user.is_admin

      assert {:ok, {user, []}} = Accounts.set_admin(actor, user, true)
      assert user.is_admin
      assert Accounts.get_user!(user.id).is_admin
    end

    test "revokes the role when another admin remains", %{actor: actor} do
      other = admin_fixture()

      assert {:ok, {other, _tokens}} = Accounts.set_admin(actor, other, false)
      refute other.is_admin
      assert Accounts.get_user!(actor.user.id).is_admin
    end

    test "returns the demoted user's session tokens so their LiveViews can be cut off",
         %{actor: actor} do
      other = admin_fixture()
      token = Accounts.generate_user_session_token(other)

      assert {:ok, {_other, tokens}} = Accounts.set_admin(actor, other, false)
      assert Enum.any?(tokens, &(&1.token == token))
    end

    test "returns no tokens when promoting", %{actor: actor} do
      user = user_fixture()
      Accounts.generate_user_session_token(user)

      assert {:ok, {_user, []}} = Accounts.set_admin(actor, user, true)
    end

    test "refuses to revoke the last admin, including yourself", %{actor: actor} do
      _member = user_fixture()
      assert Accounts.count_admins() == 1

      assert {:error, :last_admin} = Accounts.set_admin(actor, actor.user, false)
      assert Accounts.get_user!(actor.user.id).is_admin
    end

    test "is a no-op when the role already matches", %{actor: actor} do
      user = user_fixture()
      assert {:ok, {^user, []}} = Accounts.set_admin(actor, user, false)
    end

    test "refuses an actor who is not an admin" do
      actor = user_scope_fixture()
      target = user_fixture()

      assert {:error, :unauthorized} = Accounts.set_admin(actor, target, true)
      refute Accounts.get_user!(target.id).is_admin
    end

    test "refuses an actor whose admin role was revoked while they held a page open" do
      keeper = admin_fixture()
      demoted = admin_fixture()
      stale_scope = user_scope_fixture(demoted)

      {:ok, {_demoted, _}} = Accounts.set_admin(user_scope_fixture(keeper), demoted, false)

      target = user_fixture()
      assert {:error, :unauthorized} = Accounts.set_admin(stale_scope, target, true)
      refute Accounts.get_user!(target.id).is_admin
    end

    test "refuses an anonymous scope" do
      target = user_fixture()

      assert {:error, :unauthorized} =
               apply(Accounts, :set_admin, [Scope.for_user(nil), target, true])
    end

    test "refuses an admin whose session is authenticated but no longer fresh" do
      # `mix phx.gen.auth` puts renaming your own account behind sudo mode. Granting the
      # admin role is strictly more dangerous — without this, a borrowed laptop or a
      # lifted remember-me cookie is refused its own settings page while still being
      # able to mint a new administrator through the public registration form.
      admin = admin_fixture()
      target = user_fixture()

      assert {:error, :sudo_required} =
               Accounts.set_admin(stale_scope(admin), target, true)

      refute Accounts.get_user!(target.id).is_admin

      # ...and the identical call from a fresh session still works, so the guard is
      # discriminating on freshness and nothing else.
      assert {:ok, {_target, []}} =
               Accounts.set_admin(user_scope_fixture(admin), target, true)
    end

    test "the sudo window is the one Accounts publishes, not a second hard-coded copy" do
      admin = admin_fixture()
      target = user_fixture()

      # One second inside the window succeeds; one second outside it does not.
      inside = DateTime.add(DateTime.utc_now(:second), -19 * 60 - 59, :second)
      outside = DateTime.add(DateTime.utc_now(:second), -20 * 60 - 1, :second)

      assert {:error, :sudo_required} =
               Accounts.set_admin(
                 user_scope_fixture(admin, authenticated_at: outside),
                 target,
                 true
               )

      assert {:ok, {_target, []}} =
               Accounts.set_admin(
                 user_scope_fixture(admin, authenticated_at: inside),
                 target,
                 true
               )
    end

    test "reports a target that no longer exists", %{actor: actor} do
      user = user_fixture()
      Repo.delete!(user)

      assert {:error, :not_found} = Accounts.set_admin(actor, user, true)
    end

    test "re-reads the user, so a stale struct cannot resurrect a revoked role",
         %{actor: actor} do
      admin = admin_fixture()
      {:ok, _} = Accounts.set_admin(actor, admin, false)

      # `admin` still says is_admin: true
      assert admin.is_admin
      assert {:ok, {user, []}} = Accounts.set_admin(actor, admin, false)
      refute user.is_admin
    end

    test "cannot be used to change anything else", %{actor: actor} do
      user = user_fixture()
      original_email = user.email

      {:ok, {updated, []}} = Accounts.set_admin(actor, user, true)
      assert updated.email == original_email

      # The real guarantee is in the changeset: it casts nothing but :is_admin, so an
      # admin-only endpoint cannot be used to smuggle in an email or password change.
      changeset =
        User.admin_changeset(user, %{
          is_admin: true,
          email: "attacker@example.com",
          username: "attacker",
          hashed_password: "planted",
          confirmed_at: DateTime.utc_now(:second)
        })

      assert Map.keys(changeset.changes) == [:is_admin]

      assert %{is_admin: ["can't be blank"]} =
               errors_on(User.admin_changeset(user, %{is_admin: nil}))
    end
  end

  describe "delete_user/2" do
    setup do
      %{actor: admin_scope_fixture(%{username: "deleteactor"})}
    end

    test "refuses an admin whose session is authenticated but no longer fresh" do
      admin = admin_fixture()
      user = user_fixture()

      assert {:error, :sudo_required} = Accounts.delete_user(stale_scope(admin), user)
      assert Accounts.get_user(user.id)

      assert {:ok, {_deleted, _tokens}} =
               Accounts.delete_user(user_scope_fixture(admin), user)

      refute Accounts.get_user(user.id)
    end

    test "returns the deleted user's session tokens so their LiveViews can be cut off",
         %{actor: actor} do
      # The row is gone but the socket is not. Without these tokens the caller has
      # nothing to broadcast on, and the deleted person keeps a live LiveView running
      # on a scope with no account behind it.
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, {_deleted, tokens}} = Accounts.delete_user(actor, user)
      assert Enum.any?(tokens, &(&1.token == token))
    end

    test "deletes a member and frees their email and username", %{actor: actor} do
      user = user_fixture(%{username: "goner", email: "goner@example.com"})
      Accounts.generate_user_session_token(user)

      assert {:ok, _deleted} = Accounts.delete_user(actor, user)

      refute Accounts.get_user_by_username("goner")
      refute Accounts.get_user_by_email("goner@example.com")
      # The unique indexes no longer block a fresh registration.
      assert {:ok, _} =
               Accounts.register_user(%{
                 username: "goner",
                 email: "goner@example.com",
                 password: valid_user_password()
               })
    end

    test "takes the user's session tokens with it", %{actor: actor} do
      user = user_fixture()
      Accounts.generate_user_session_token(user)
      assert Repo.all_by(UserToken, user_id: user.id) != []

      assert {:ok, _} = Accounts.delete_user(actor, user)
      assert Repo.all_by(UserToken, user_id: user.id) == []
    end

    test "refuses to delete an admin", %{actor: actor} do
      other = admin_fixture()

      assert {:error, :is_admin} = Accounts.delete_user(actor, other)
      assert Accounts.get_user!(other.id)
    end

    test "refuses to delete yourself", %{actor: actor} do
      assert {:error, :self} = Accounts.delete_user(actor, actor.user)
      assert Accounts.get_user!(actor.user.id)
    end

    test "refuses a non-admin actor" do
      actor = user_scope_fixture()
      target = user_fixture()

      assert {:error, :unauthorized} = Accounts.delete_user(actor, target)
      assert Accounts.get_user!(target.id)
    end

    test "refuses an anonymous scope" do
      target = user_fixture()

      assert {:error, :unauthorized} = apply(Accounts, :delete_user, [nil, target])
      assert Accounts.get_user!(target.id)
    end

    test "reports a target that is already gone", %{actor: actor} do
      user = user_fixture()
      Repo.delete!(user)

      assert {:error, :not_found} = Accounts.delete_user(actor, user)
    end
  end
end
