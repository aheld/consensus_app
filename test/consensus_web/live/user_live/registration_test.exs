defmodule ConsensusWeb.UserLive.RegistrationTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  alias Consensus.Accounts

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
      assert html =~ "Username"
      assert html =~ "Password"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(
          user: %{
            "email" => "with spaces",
            "username" => "no spaces here!",
            "password" => "short"
          }
        )

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "may only contain letters, numbers, underscores and hyphens"
      assert result =~ "should be at least 12 character"
    end
  end

  describe "register user" do
    test "creates an account and logs the new user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      username = unique_username()

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(email: email, username: username)
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      user = Accounts.get_user_by_username(username)
      assert user.email == email
      refute user.is_admin
      assert Accounts.get_user_by_login_and_password(username, valid_user_password())
      assert Accounts.get_user_by_login_and_password(email, valid_user_password())
    end

    test "the registration form offers no way to ask for the admin role", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      refute html =~ "is_admin"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: user.email))
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders errors for duplicated username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{username: "takenname"})

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(username: user.username))
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "usernames are compared case-insensitively", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user_fixture(%{username: "casetest"})

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(username: "CaseTest"))
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      # By id, not by text: the global header's `⋯` menu (D-041) also offers "Log in"
      # to a signed-out visitor, so "the anchor inside <main> whose text is Log in" now
      # matches two elements. This asserts on the body's own link, which is the one
      # this test has always been about.
      {:ok, _login_live, login_html} =
        lv
        |> element("#register-log-in-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end

  describe "the two registration paths" do
    test "the username & password path is the default and shows a password field", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, ~s(input[name="user[password]"]))
    end

    test "choosing the magic-link path hides the password field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html = render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      refute has_element?(lv, ~s(input[name="user[password]"]))
      assert html =~ "Send magic link"
    end

    test "switching back to the password path restores the field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      render_click(lv, "choose_mode", %{"mode" => "magic_link"})
      render_click(lv, "choose_mode", %{"mode" => "password"})

      assert has_element?(lv, ~s(input[name="user[password]"]))
    end

    test "registers the account and sends a sign-in link, without logging in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      email = unique_user_email()
      username = unique_username()

      html =
        lv
        |> form("#registration_form", user: %{"email" => email, "username" => username})
        |> render_submit()

      # A full-page state of this LiveView, not a flash on a screen the account is
      # nowhere on (D-045).
      assert html =~ "Account created"
      assert html =~ email
      assert html =~ "Send the link again"
      refute has_element?(lv, "#registration_form")

      user = Accounts.get_user_by_username(username)
      assert user.email == email
      refute user.confirmed_at
      # **No placeholder password.** This path used to inject a random one to satisfy the
      # registration changeset, which left `hashed_password` non-nil — the one field
      # `UserSessionController.clears_password?/1` reads — so every magic-link signup was
      # told on its first sign-in that "the password that was set on this account has been
      # removed", naming a password nobody had ever chosen. See D-045.
      refute user.hashed_password

      assert Consensus.Repo.get_by!(Consensus.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    # The screen must not lie about what it just did. It used to reassure the reader that
    # "nothing was confirmed to it and nobody can sign in with it" — twenty lines under the
    # address it had just mailed a working sign-in link to. `login_user_by_magic_link/1`
    # confirms the account and signs the holder in (invariant 7), so whoever owns a
    # mistyped mailbox can take the account, under the username the registrant chose.
    test "the sent screen tells the truth about a mistyped address", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      username = unique_username()

      html =
        lv
        |> form("#registration_form",
          user: %{"email" => unique_user_email(), "username" => username}
        )
        |> render_submit()

      refute html =~ "nobody can sign in with it"
      assert html =~ "whoever owns that mailbox could take this account"
      # The username is named rather than pointed at — "the one above is taken now" was a
      # reference to a screen that renders only the email address.
      assert html =~ username
      # And the correction path is its own 44px control, not an inline link that wraps.
      assert has_element?(lv, ~s|#registration-sent-restart[class*="min-h-[44px]"]|)
    end

    # Each press mints a login token and mails an address this app has not verified, so an
    # unbounded button on an unauthenticated screen is a mail cannon aimed at any third
    # party whose address someone types in. The guard is in the handler, not just the
    # template: an absent button is a client-side hint and the event can still be pushed.
    test "resending is bounded", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      username = unique_username()

      lv
      |> form("#registration_form",
        user: %{"email" => unique_user_email(), "username" => username}
      )
      |> render_submit()

      user = Accounts.get_user_by_username(username)

      render_click(lv, "resend")
      html = render_click(lv, "resend")

      refute has_element?(lv, "#registration-sent-resend")
      assert html =~ "That is as many as we will send"

      login_tokens = login_token_count(user)

      # A forged press past the limit sends nothing.
      render_click(lv, "resend")
      assert login_token_count(user) == login_tokens
    end

    # The sent screen used to instruct a press it had just removed: the fallback paragraph
    # said "Check the spam folder, then send it again" while
    # `#registration-sent-resend-exhausted` directly beneath it said that is as many as we
    # will send, and the button between them was gone. Same defect `UserLive.Login` carried
    # on its own fallback; both are branched on the same budget the button branches on.
    test "the exhausted sent screen never points at the resend button it has removed",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      html =
        lv
        |> form("#registration_form",
          user: %{"email" => unique_user_email(), "username" => unique_username()}
        )
        |> render_submit()

      assert html =~ "send it again"

      render_click(lv, "resend")
      html = render_click(lv, "resend")

      refute has_element?(lv, "#registration-sent-resend")
      assert has_element?(lv, "#registration-sent-resend-exhausted")
      refute html =~ "send it again"
      # The remedy that does exist is still named, and its control is still on the screen.
      assert has_element?(lv, "#registration-sent-restart")
    end

    # The whole point of dropping the placeholder: end to end, from the chip to the flash.
    test "opening the emailed link does not claim a password was removed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      email = unique_user_email()
      username = unique_username()

      lv
      |> form("#registration_form", user: %{"email" => email, "username" => username})
      |> render_submit()

      user = Accounts.get_user_by_username(username)
      token = extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")
      # And the screen before the button does not warn either — `Confirmation` reads the
      # same `hashed_password` field, so the two used to be wrong together.
      refute has_element?(lv, "#password-clears-warning")

      conn = lv |> form("#confirmation_form") |> submit_form(conn)

      refute Phoenix.Flash.get(conn.assigns.flash, :info) =~ "has been removed"
      assert Accounts.get_user_by_username(username).confirmed_at
    end

    test "the magic-link path still offers no way to ask for the admin role", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html = render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      refute html =~ "is_admin"
    end

    test "the magic-link path still enforces validation on email and username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      render_click(lv, "choose_mode", %{"mode" => "magic_link"})

      result =
        lv
        |> form("#registration_form", user: %{"email" => "with spaces", "username" => "no!"})
        |> render_change()

      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "may only contain letters, numbers, underscores and hyphens"
      refute result =~ "should be at least 12 character"
    end
  end

  # D-045. Every control in the global footer and the header `‹` is a `navigate`, so a tap
  # on one remounts this LiveView and the typing is gone with no confirm and no undo. The
  # mechanism (`footer_confirm` / `back_confirm`) shipped with D-041 and had zero call
  # sites app-wide; these are the call sites.
  describe "the unsaved-draft guard" do
    test "is disarmed on an untouched form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      refute has_element?(lv, "#chrome-back[data-confirm]")
      refute has_element?(lv, "footer a[data-confirm]")
    end

    test "arms the header back and every footer link once anything is typed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      lv |> form("#registration_form", user: %{"username" => "jo"}) |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
      assert has_element?(lv, "footer a[data-confirm]")
      # (The `⋯` menu is guarded too, but it is not rendered on this screen —
      # `Chrome.menu_worth_opening?/2` drops it on the two auth forms. Asserted on
      # `/users/settings` instead, in `ConsensusWeb.UserLive.SettingsTest`.)
    end

    # The exit the sweep missed. With text typed into USERNAME the page carried seven
    # `[data-confirm]` nodes — the header `‹`, both footer faces, the three standing links
    # and the credit — and not this one, which sits directly above the form and is the
    # single most likely reason to leave mid-typing. `settings.ex` and `group_live/new.ex`
    # are the other two screens holding a draft and neither has an in-page nav link, so
    # this was the only remaining gap.
    test "the in-page 'Log in' link is guarded too", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      refute has_element?(lv, "#register-log-in-link[data-confirm]")

      lv |> form("#registration_form", user: %{"username" => "jo"}) |> render_change()

      assert has_element?(lv, "#register-log-in-link[data-confirm]")
    end

    # `draft?` reads the typed params, so an untouched form has nothing to lose in either
    # mode.
    test "stays disarmed in magic-link mode on an untouched form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      render_click(lv, "choose_mode", %{"mode" => "magic_link"})
      lv |> form("#registration_form", user: %{"username" => ""}) |> render_change()

      refute has_element?(lv, "#chrome-back[data-confirm]")
    end
  end

  defp login_token_count(user) do
    Consensus.Repo.all(Consensus.Accounts.UserToken)
    |> Enum.count(&(&1.user_id == user.id and &1.context == "login"))
  end
end
