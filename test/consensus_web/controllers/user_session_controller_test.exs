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

    # **The first sentence a brand-new account ever sees**, and it had zero coverage —
    # `grep -rn "confirmed successfully" test/` returned nothing, which is why the
    # generator's "User confirmed successfully." survived a sweep that purged six
    # "group"→"session" strings elsewhere. A schema noun addressing the reader in the third
    # person, on the screen that finishes signing up.
    test "the confirm action greets the reader in this app's voice, not the generator's", %{
      conn: conn,
      user: user
    } do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      flash = Phoenix.Flash.get(conn.assigns.flash, :info)

      assert flash =~ "You're in"
      refute flash =~ "User confirmed"
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

  # D-045. `ConsensusWeb.AdminLive.Users` promised "you will come back to Admin → Users"
  # and could not keep it: `user_return_to` was only ever written by a plug on GET
  # requests, and that navigation originates in a LiveView. `UserLive.Login` now carries
  # the destination through as a hidden `user[return_to]` and this controller stores it.
  describe "POST /users/log-in - the return trip" do
    test "an internal path is honoured", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "return_to" => "/admin/users"
          }
        })

      assert redirected_to(conn) == ~p"/admin/users"
    end

    # This writes a value a *successful authentication* then redirects to, which is the
    # single most valuable place in an app to have an open redirect — the victim arrives
    # already convinced. Every one of these must fall back to `signed_in_path/1`, and a
    # rejection must be silent rather than an error message that teaches the filter's
    # shape.
    test "an off-site destination is refused in every spelling", %{user: user} do
      user = set_password(user)

      for hostile <- [
            "https://evil.example/pwn",
            "http://evil.example",
            "//evil.example/pwn",
            "/\\evil.example/pwn",
            "javascript:alert(1)",
            "evil.example",
            # The three `Phoenix.Controller`'s own `@invalid_local_url_chars` refuses.
            # `safe_return_to/1` used to pass all three, so `redirect(to: …)` raised
            # `ArgumentError` *after* the password had been checked: a correct log-in
            # answered 500 and left the browser signed out, repeatably, from a link an
            # attacker handed out. The reason they are unsafe rather than merely odd is
            # that the WHATWG URL parser strips ASCII tab/LF/CR before resolving, so
            # `/\tevil.example` survives a prefix test and then resolves protocol-relative.
            # These assert a *redirect to `/`*, which is what proves no raise happened.
            "/%09//evil.example",
            "/\t/evil.example",
            "/a\\b"
          ] do
        conn =
          build_conn()
          |> post(~p"/users/log-in", %{
            "user" => %{
              "email" => user.email,
              "password" => valid_user_password(),
              "return_to" => hostile
            }
          })

        assert redirected_to(conn) == ~p"/",
               "#{inspect(hostile)} was honoured as a log-in destination"

        refute conn.assigns.flash["error"]
      end
    end

    test "the log-in screen renders the destination as a hidden field", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?#{[return_to: ~p"/admin/users"]}")
      body = html_response(conn, 200)

      assert body =~ ~s(name="user[return_to]")
      assert body =~ ~s(value="/admin/users")
    end

    test "the log-in screen drops an off-site destination rather than rendering it",
         %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?#{[return_to: "https://evil.example/pwn"]}")
      body = html_response(conn, 200)

      # The hidden field is the only thing on this page that feeds
      # `UserAuth.store_return_to/2`, so it is what must be absent. (The raw query string
      # still appears percent-encoded inside the footer's own `?return_to=` links, which
      # is `ConsensusWeb.Chrome`'s pre-existing behaviour and inert: those are internal
      # paths back to this same screen, where this filter runs again.)
      refute body =~ ~s(name="user[return_to]")
      refute body =~ ~s(value="https://evil.example/pwn")
    end
  end

  # `renew_session/2` clears the whole session to defeat fixation, and it used to take a
  # guest's ballot receipt with it. A guest has no account (product invariant 1), so
  # `"participant_token:<group_id>"` is the *only* record that they joined a vote and cast
  # it — and the trigger is one tap from the ballot, because every `/join` screen renders a
  # "Create your own →" pill. Measured before the fix: vote, log in, and `/join/:slug/vote`
  # bounced back to the name-entry screen, where `JoinController.resolve_guest/3` — whose
  # only dedupe *is* that key — would mint a second participant row and count one person
  # twice in the tally.
  describe "a guest's participant token survives signing in" do
    import Consensus.VotingFixtures

    alias ConsensusWeb.JoinAuth

    test "logging in keeps the ballot reachable and does not offer a second identity",
         %{conn: conn, user: user} do
      user = set_password(user)
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "Nadia"})
      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"
      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      assert is_binary(token)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token), "the log-in itself must still work"
      assert get_session(conn, JoinAuth.participant_session_key(group.id)) == token

      # And the ballot still renders rather than redirecting back to name entry.
      conn = get(conn, ~p"/join/#{group.slug}/vote")
      assert html_response(conn, 200)
    end

    test "logging out keeps it too — a guest's vote is not an account credential",
         %{conn: conn, user: user} do
      user = set_password(user)
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "Nadia"})
      token = get_session(conn, JoinAuth.participant_session_key(group.id))

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      conn = delete(conn, ~p"/users/log-out")

      refute get_session(conn, :user_token)
      assert get_session(conn, JoinAuth.participant_session_key(group.id)) == token
    end
  end
end
