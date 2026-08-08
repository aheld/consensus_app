defmodule ConsensusWeb.UserSessionControllerTest do
  use ConsensusWeb.ConnCase

  import Consensus.AccountsFixtures
  alias Consensus.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_consensus_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email/username or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "flashes back the identifier that was typed, so the form can refill it", %{conn: conn} do
      # The generator flashes `:email`; the field here is `login` (email OR username),
      # so the key differs. `ConsensusWeb.UserLive.Login.mount/3` reads exactly this.
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"login" => "nobody@example.com", "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :login) == "nobody@example.com"
    end

    test "truncates the identifier it flashes back", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"login" => String.duplicate("a", 300), "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :login) == String.duplicate("a", 160)
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "does not claim a password was removed when the account never had one", %{conn: conn} do
      # The end state D-017 produces for every account this app reclaims: confirmed, no
      # password. It is reached by the app's own advertised recovery path, so it is the
      # *normal* state for such a user, and every subsequent "Log in with email" used to
      # tell them "The password that was set on this account has been removed" — nothing
      # was set and nothing was removed. A warning that fires on every routine login is
      # noise by the second login, and the one time it is true (a squatter's credential
      # actually being destroyed) it gets scrolled past.
      unconfirmed = unconfirmed_user_fixture()
      {discarding_token, _} = generate_user_magic_link_token(unconfirmed)
      {:ok, {user, _}} = Consensus.Accounts.login_user_by_magic_link(discarding_token)

      assert user.confirmed_at, "the reclaim should have confirmed the account"
      refute user.hashed_password, "the reclaim should have discarded the password"

      {token, _} = generate_user_magic_link_token(user)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome back!"

      refute Phoenix.Flash.get(conn.assigns.flash, :info) =~ "has been removed",
             "claimed a password was removed from an account that had none"
    end

    test "confirms unconfirmed user who is signed in, still discarding the password", %{
      conn: conn,
      unconfirmed_user: user
    } do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      # Being signed in earns no exception: for an unconfirmed account that session
      # can only have come from registration, i.e. from the suspect password itself.
      # See `Accounts.login_user_by_magic_link/1`.
      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "The password that was set on this account has been removed"

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.confirmed_at
      assert is_nil(reloaded.hashed_password)

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "an attacker's pre-stuffed password is dead once the victim clicks the link", %{
      conn: conn
    } do
      # 1. The attacker registers the victim's address with a password they know, and
      #    keeps the session cookie that registration handed them.
      {:ok, victim_account} =
        Accounts.register_user(%{
          email: "victim@example.com",
          username: "victim",
          password: "attackers password"
        })

      attacker_conn =
        post(build_conn(), ~p"/users/log-in", %{
          "user" => %{"login" => "victim", "password" => "attackers password"}
        })

      assert get_session(attacker_conn, :user_token)

      # 2. The victim, who controls the inbox, clicks their magic link. The stuffed
      #    session cookie riding along in that browser must not save the password.
      {token, _hashed_token} = generate_user_magic_link_token(victim_account)

      victim_conn =
        conn
        |> log_in_user(victim_account)
        |> post(~p"/users/log-in", %{"user" => %{"token" => token}})

      assert get_session(victim_conn, :user_token)
      assert Accounts.get_user!(victim_account.id).confirmed_at

      # 3. A fresh browser with the attacker's credential is now refused.
      replay =
        post(build_conn(), ~p"/users/log-in", %{
          "user" => %{"login" => "victim", "password" => "attackers password"}
        })

      refute get_session(replay, :user_token)
      assert redirected_to(replay) == ~p"/users/log-in"

      assert Phoenix.Flash.get(replay.assigns.flash, :error) ==
               "Invalid email/username or password"

      refute Accounts.get_user_by_login_and_password("victim", "attackers password")
      refute Accounts.get_user_by_login_and_password("victim@example.com", "attackers password")
    end

    test "broadcasts a disconnect for every token the magic link expires", %{
      conn: conn,
      user: user
    } do
      # `UserAuth.disconnect_sessions/1` is what cuts off a LiveView already mounted
      # with a token this login just deleted. Deleting the call from the controller
      # leaves every other test green, so assert the broadcast itself.
      session_token = Accounts.generate_user_session_token(user)
      topic = "users_sessions:" <> Base.url_encode64(session_token)
      ConsensusWeb.Endpoint.subscribe(topic)

      {token, _hashed_token} = generate_user_magic_link_token(user)

      # A confirmed user's magic link only deletes the magic-link token, so confirm
      # via an unconfirmed account instead to get session tokens in the expired set.
      unconfirmed = unconfirmed_user_fixture()
      unconfirmed_session_token = Accounts.generate_user_session_token(unconfirmed)
      unconfirmed_topic = "users_sessions:" <> Base.url_encode64(unconfirmed_session_token)
      ConsensusWeb.Endpoint.subscribe(unconfirmed_topic)
      {unconfirmed_magic, _} = generate_user_magic_link_token(unconfirmed)

      post(conn, ~p"/users/log-in", %{"user" => %{"token" => unconfirmed_magic}})

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^unconfirmed_topic}

      # and the unrelated user's live session is left alone
      post(build_conn(), ~p"/users/log-in", %{"user" => %{"token" => token}})
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
