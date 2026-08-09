defmodule ConsensusWeb.UserLive.SettingsTest do
  use ConsensusWeb.ConnCase

  alias Consensus.Accounts
  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Send a confirmation link"
      assert html =~ "Save password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    # The bounce carries `?return_to=/users/settings` (D-045). A hook runs in a LiveView
    # and cannot write `:user_return_to` into a session, so the destination travels in the
    # log-in URL and `UserAuth.store_return_to/2` re-validates it on the way back in —
    # without it, logging in again lands on `signed_in_path/1` rather than on the screen
    # the person was thrown out of.
    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in?#{[return_to: ~p"/users/settings"]}")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
      # And the form that can keep the promise renders it, with the hidden field behind it.
      assert conn.resp_body =~ "Logging in with your password brings you straight back"
      assert conn.resp_body =~ ~s(name="user[return_to]")
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      # A full-page state, not a flash on a settings form still showing the old address —
      # which read as "nothing happened" (D-045).
      assert result =~ "Confirm the new address"
      assert result =~ new_email
      assert result =~ "changed yet"
      refute has_element?(lv, "#email_form")

      # The two escape hatches: resend, and go back and fix a typo.
      assert has_element?(lv, "#email-change-back")
      assert Accounts.get_user_by_email(user.email)
    end

    test "the sent screen resends, and can be dismissed back to the form", %{conn: conn} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#email_form", %{"user" => %{"email" => new_email}})
      |> render_submit()

      html = render_click(lv, "resend_email_change")

      # **One** change-email token, not two. The resend genuinely sent — the flash says so
      # and the mailer was called — but `Accounts.deliver_user_update_email_instructions/3`
      # now deletes every outstanding `change:` token for the account before inserting the
      # new one, so the previous link is dead rather than a second live seven-day key to
      # this account sitting in a mailbox. That is what makes the sentence this screen
      # prints — "sending a new one cancels the one already out" — true rather than
      # reassuring, and it is the property a typo'd address depends on. A "Send it again"
      # control that quietly does nothing is still the dead end this screen replaced, so
      # the flash is asserted too.
      assert html =~ "Sent again."

      change_tokens =
        Consensus.Repo.all(Consensus.Accounts.UserToken)
        |> Enum.count(&String.starts_with?(&1.context, "change:"))

      assert change_tokens == 1

      html = render_click(lv, "back_to_settings")
      assert has_element?(lv, "#email_form")
      assert html =~ "Send a confirmation link"
      # The field comes back holding the unsaved address, so the draft guard has to come
      # back armed with it. `update_email` sets `email_draft?` false because the form left
      # the screen; `back_to_settings` has to undo that, or the one screen state where
      # there is provably something to lose is the one state with no prompt on the exits.
      assert has_element?(lv, "#chrome-back[data-confirm]")
      assert has_element?(lv, "footer a[data-confirm]")
    end

    # Milder than `login.ex`'s — sudo-gated, and the address was typed by the signed-in
    # owner — but the recipient is a **new** address, so a mistyped or hostile value lands
    # in a mailbox the account holder does not control. Bounded for the same reason, and
    # `update_email` shares the budget: capping only the resend button left the identical
    # send one event name away, and the guard is a clause head because a `phx-click` can be
    # pushed at any socket.
    test "the screen shares one budget across update_email and resend", %{conn: conn, user: user} do
      budget = ConsensusWeb.UserLive.Settings.max_sends()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
      |> render_submit()

      for _ <- 2..budget, do: render_click(lv, "resend_email_change")

      refute has_element?(lv, "button[phx-click='resend_email_change']")
      assert has_element?(lv, "#email-change-resend-exhausted")

      # `deliver_user_update_email_instructions/3` deletes the account's outstanding
      # `change:` tokens before inserting a new one, so a *count* can never show the spend
      # — there is always exactly one. The token **value** can: a send replaces it, a
      # refusal leaves it alone.
      spent = change_token(user)
      assert spent

      # Forged presses past the limit send nothing — neither event, because the guard is a
      # clause head and both handlers spend the same budget.
      render_click(lv, "resend_email_change")
      assert change_token(user) == spent

      render_submit(lv, "update_email", %{"user" => %{"email" => unique_user_email()}})
      assert change_token(user) == spent
    end

    # The budget being shared has a copy consequence, and the copy did not follow it here
    # the way it did on `login.ex`. Walk the exact path this screen *instructs*: exhaust the
    # budget, press "Back to settings — the address was wrong", retype a corrected address,
    # submit. Nothing is sent — and the unconditional lede then asserted "the link we just
    # sent to: <address>" over an address no mail ever went to, with no "Send it again"
    # button anywhere on the page and the only guidance on screen being the path that had
    # just silently failed. A false claim of a sent link, on an account-recovery flow.
    test "with the budget spent, the screen says no link was sent rather than asserting one",
         %{conn: conn, user: user} do
      budget = ConsensusWeb.UserLive.Settings.max_sends()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
      |> render_submit()

      for _ <- 2..budget, do: render_click(lv, "resend_email_change")
      spent = change_token(user)

      render_click(lv, "back_to_settings")

      corrected = unique_user_email()

      html =
        lv
        |> form("#email_form", %{"user" => %{"email" => corrected}})
        |> render_submit()

      assert change_token(user) == spent, "a refused send must mint nothing"

      assert html =~ "No link was sent"
      assert html =~ "Reload it to start again"
      refute html =~ "the link we just sent to"

      # And the instruction it offers is no longer the one that just failed.
      refute html =~ "go back and try a different address"
    end

    # **The lede was branched and the two blocks under it were not, which is worse than
    # leaving all three wrong** — the screen said "No link was sent" and then, 40px lower,
    # gave three separate pieces of advice about the message it had just said did not
    # exist, in the app's most confident voice, on an account-recovery path. Every string
    # below was on screen at the same time as "No link was sent" before this test existed.
    #
    # `<:fallback>` and the exhausted `<:actions>` line both branch on
    # `@email_send_refused?` now, not on `@sends_left` — those are different conditions and
    # the difference is the point: the budget can be spent on a send that really went out
    # (the reader arrived on the last one), and that reader *should* be told to check the
    # spam folder.
    test "with the budget spent, nothing on the screen describes a message", %{
      conn: conn,
      user: user
    } do
      budget = ConsensusWeb.UserLive.Settings.max_sends()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
      |> render_submit()

      for _ <- 2..budget, do: render_click(lv, "resend_email_change")
      spent = change_token(user)

      render_click(lv, "back_to_settings")

      html =
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()

      assert change_token(user) == spent

      for lie <- [
            "spam folder",
            "already out",
            "last one we&#39;ll send",
            "mailbox you don&#39;t own",
            "Nothing after a minute or two",
            # `check_your_email/1`'s own dev card, the fourth false line — it renders
            # unconditionally in dev and says "The message is waiting in the local
            # mailbox". It takes `sent?` now.
            "The message is waiting in"
          ] do
        refute html =~ lie, "the refused-send screen still describes a message: #{lie}"
      end

      assert html =~ "There is nothing to wait for."
      assert html =~ "Nothing was sent"

      # A green "Sent again." from an earlier resend survived the round trip through
      # `back_to_settings` and repainted directly above "No link was sent."
      refute html =~ "Sent again."
    end

    # There is deliberately no test for `resend_email_change` outside the sudo window.
    # The LiveView holds the `%User{}` it mounted with, so `Accounts.sudo_mode?/1` compares
    # a frozen `authenticated_at` against a moving `utc_now/0`: reaching the `else` branch
    # needs the page to have been open for more than 20 minutes, which no seam in this
    # suite can fake (mounting with an already-aged token is rejected 10 minutes earlier by
    # the `:require_sudo_mode` hook). The branch exists because that is the *ordinary* way
    # to use this screen — go to your inbox, come back late, tap "Send it again" — and
    # `true = Accounts.sudo_mode?(user)` made it a `MatchError` behind a tangerine primary
    # button. See `ConsensusWeb.UserSessionController.update_password/2` for the same fix
    # on the same generator line.

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Send a confirmation link"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Send a confirmation link"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end

    # **The sudo bounce must not throw the token away.** `UserLive.Settings` declares
    # `{:require_sudo_mode, "/users/settings"}` once, at module level, and serves two
    # routes; this is the second one, and it is the one where exceeding the 10-minute
    # window is the *ordinary* case, because the link is emailed and therefore read later.
    # With a static return path the bounce sent the person to `?return_to=/users/settings`,
    # discarded the token, and after re-authenticating landed them on the settings form with
    # the old address still in it and nothing on screen saying the click had done nothing.
    test "a stale session bounces to log-in carrying the token, not just the settings path",
         %{token: token, user: user} do
      conn =
        build_conn()
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      {:error, {:redirect, %{to: path}}} =
        live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert path ==
               ~p"/users/log-in?#{[return_to: ~p"/users/settings/confirm-email/#{token}"]}"
    end
  end

  describe "update username form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the username", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#username_form", %{"user" => %{"username" => "brandnew"}})
        |> render_submit()

      assert result =~ "Username changed to brandnew"
      assert Accounts.get_user!(user.id).username == "brandnew"
      assert Accounts.get_user_by_login_and_password("brandnew", valid_user_password())
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#username_form")
        |> render_change(%{"user" => %{"username" => "no spaces"}})

      assert result =~ "may only contain letters, numbers, underscores and hyphens"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      other = user_fixture(%{username: "alreadytaken"})
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#username_form", %{"user" => %{"username" => other.username}})
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  # D-045. Three independent forms, so three independent answers to "is there anything
  # here to lose" — one shared boolean would clear the other two forms' drafts on every
  # keystroke. Username and email arrive pre-filled, so the comparison is "differs from
  # what is stored", not "non-empty".
  describe "the unsaved-draft guard" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "is disarmed on an untouched page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      refute has_element?(lv, "#chrome-back[data-confirm]")
      refute has_element?(lv, "footer a[data-confirm]")
    end

    test "stays disarmed when a pre-filled field is re-submitted unchanged", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#email_form", user: %{"email" => user.email}) |> render_change()

      refute has_element?(lv, "#chrome-back[data-confirm]")
    end

    test "arms on a changed username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#username_form", user: %{"username" => "somethingelse"}) |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
      assert has_element?(lv, "footer a[data-confirm]")
    end

    test "arms on a changed email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#email_form", user: %{"email" => "new@example.com"}) |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
    end

    test "arms on a typed password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#password_form", user: %{"password" => "hunter22hunter22"})
      |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
    end

    test "one form's draft is not cleared by another form's keystroke", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#username_form", user: %{"username" => "somethingelse"}) |> render_change()
      lv |> form("#email_form", user: %{"email" => user.email}) |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
    end

    # The last unguarded exits. Measured on `/groups/new` holding a typed title, the page
    # carried seven `data-confirm` elements — the `‹` and six footer links — and the `⋯`
    # menu's Admin / Settings / Log out carried none, so tapping one took the draft with
    # it, silently. Every door out of a screen with a draft in it takes the same prompt.
    test "the ⋯ menu's entries are guarded too", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      refute has_element?(lv, "#chrome-menu a[data-confirm]")

      lv |> form("#username_form", user: %{"username" => "somethingelse"}) |> render_change()

      assert has_element?(lv, "#chrome-menu a[data-confirm]")
    end
  end

  # The account's single outstanding change-address token, by value. `Accounts` deletes any
  # previous one before inserting, so this is unique when it exists and `nil` when it does
  # not.
  defp change_token(user) do
    Consensus.Repo.all(Consensus.Accounts.UserToken)
    |> Enum.find(&(&1.user_id == user.id and String.starts_with?(&1.context, "change:")))
    |> then(&(&1 && &1.token))
  end
end
