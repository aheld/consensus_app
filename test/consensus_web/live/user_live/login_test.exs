defmodule ConsensusWeb.UserLive.LoginTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Send magic link"
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()

      # A full-page state of this same LiveView, not a flash over the form it was just
      # submitted from and not a redirect to a new route (D-045).
      assert html =~ "Check your email"
      assert html =~ "If that address is in our system"
      assert html =~ user.email
      refute has_element?(lv, "#login_form_magic")

      assert Consensus.Repo.get_by!(Consensus.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()

      assert html =~ "Check your email"
      assert html =~ "If that address is in our system"
    end

    # The enumeration property, asserted as an equality rather than as the presence of a
    # hedging phrase. The success screen is a pure function of the address that was typed,
    # so byte-for-byte the two renders may differ only where the address itself appears.
    # Anything that made the screen an oracle — a different heading, a "we couldn't find
    # that" branch, a delivery receipt — breaks this.
    test "the sent screen is byte-identical for a known and an unknown address", %{conn: conn} do
      user = user_fixture()
      unknown = "nobody-at-all@example.com"

      {:ok, known_lv, _} = live(conn, ~p"/users/log-in")

      known_html =
        form(known_lv, "#login_form_magic", user: %{email: user.email}) |> render_submit()

      {:ok, unknown_lv, _} = live(conn, ~p"/users/log-in")

      unknown_html =
        form(unknown_lv, "#login_form_magic", user: %{email: unknown}) |> render_submit()

      assert String.replace(known_html, user.email, "ADDRESS") ==
               String.replace(unknown_html, unknown, "ADDRESS")
    end

    test "the sent screen offers a resend and a way back to correct the address", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      form(lv, "#login_form_magic", user: %{email: user.email}) |> render_submit()

      # Resending mints a second login token rather than doing nothing.
      render_click(lv, "resend_magic")

      assert Consensus.Repo.all(Consensus.Accounts.UserToken)
             |> Enum.count(&(&1.context == "login")) == 2

      # And the way back returns the form with the typed address still in it.
      html = render_click(lv, "edit_email")
      assert html =~ "Log in"
      assert has_element?(lv, "#login_form_magic")
      assert html =~ user.email
    end

    # Unbounded, this was an inbox-flooding primitive: an unauthenticated endpoint, an
    # attacker-supplied recipient, and one real sign-in link carrying this app's From:
    # domain per press. Measured before the cap: `users_tokens` where `context = 'login'`
    # went 25 → 32 on one submit plus six presses, with 13 live links to one address.
    #
    # Two properties, and the second is what makes the first worth anything: the guard is a
    # clause head rather than a `:if` on the button (a `phx-click` can be pushed at any
    # socket a visitor can mount), and `submit_magic` spends the *same* budget — capping
    # only the resend button left the identical primitive one event name away.
    test "the screen shares one magic-link budget across submit and resend", %{conn: conn} do
      user = user_fixture()
      budget = ConsensusWeb.UserLive.Login.max_sends()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      form(lv, "#login_form_magic", user: %{email: user.email}) |> render_submit()
      assert login_token_count() == 1

      for _ <- 2..budget, do: render_click(lv, "resend_magic")
      assert login_token_count() == budget

      refute has_element?(lv, "button[phx-click='resend_magic']")
      assert has_element?(lv, "#magic-link-resend-exhausted")

      # A forged press past the limit sends nothing.
      render_click(lv, "resend_magic")
      assert login_token_count() == budget

      # Neither does a forged submit, which is the bypass a resend-only cap left open.
      render_submit(lv, "submit_magic", %{"user" => %{"email" => user.email}})
      assert login_token_count() == budget
    end

    # The cap counts presses in *this browser*, so it is a pure function of the typed
    # string exactly like every other byte of this screen. If it were not, exhausting it
    # would be an account-enumeration oracle — which is the one thing this screen exists to
    # avoid, and the reason it never says "we already sent one".
    test "exhausting the budget looks identical for a registered and an unknown address",
         %{conn: conn} do
      user = user_fixture()
      unknown = unique_user_email()
      budget = ConsensusWeb.UserLive.Login.max_sends()

      exhaust = fn address ->
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")
        html = form(lv, "#login_form_magic", user: %{email: address}) |> render_submit()

        Enum.reduce(2..budget, html, fn _, _acc -> render_click(lv, "resend_magic") end)
      end

      known_html = exhaust.(user.email)
      unknown_html = exhaust.(unknown)

      assert known_html =~ "magic-link-resend-exhausted"

      assert String.replace(known_html, user.email, "ADDRESS") ==
               String.replace(unknown_html, unknown, "ADDRESS")
    end

    # The regression this whole state machine exists for. `deliver_magic_link/2`'s refused
    # clause used to assign the same `@sent_to` its sending clause does, so submitting a
    # **new** address past the cap rendered the full "Check your email" panel — heading,
    # spam-folder advice, the never-mailed address — for an address that received nothing.
    # Driven against the real LiveView at the time: `context = 'login'` count 4 before and 4
    # after, with `id="magic-link-sent"` in the returned HTML.
    #
    # It is the *corrected typo* path specifically, which is what makes it worse than the
    # unbounded send it replaced: the person who mistyped, went back, fixed it and pressed
    # send is told a link is on its way and waits forever.
    test "a submit past the budget renders the refused screen, not the sent one", %{conn: conn} do
      user = user_fixture()
      budget = ConsensusWeb.UserLive.Login.max_sends()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      form(lv, "#login_form_magic", user: %{email: user.email}) |> render_submit()
      for _ <- 2..budget, do: render_click(lv, "resend_magic")
      assert login_token_count() == budget

      # The recovery the screen itself offers: go back, correct the address, send.
      # (The green "Sent again." from the last real resend is still on screen here — the
      # `refute` at the end of this test is not vacuous.)
      assert render_click(lv, "edit_email") =~ "Sent again."
      corrected = unique_user_email()
      html = form(lv, "#login_form_magic", user: %{email: corrected}) |> render_submit()

      assert login_token_count() == budget, "a refused send must not mint a token"
      refute has_element?(lv, "#magic-link-sent")
      assert has_element?(lv, "#magic-link-not-sent")
      assert html =~ "Nothing was sent"
      refute html =~ "is on its way"
      refute html =~ "Check the spam folder"

      # And the way out is a real page load — the only thing that restores a per-mount
      # budget. A `phx-click` back to the form here would loop straight into this screen.
      assert has_element?(lv, "#magic-link-start-over[href='/users/log-in']")
      refute has_element?(lv, "#magic-link-edit-email")

      # And the green "Sent again." from the last real resend does not survive onto it. The
      # flash group is `sticky` and outlives a re-render, so without this the refusal
      # painted "Nothing was sent" directly under a card asserting something had been —
      # caught in a browser, not by the suite.
      refute html =~ "Sent again."
    end

    # The refused screen is as much of an enumeration oracle as the sent one, and it is
    # reached by the same count of presses whoever the address belongs to.
    test "the refused screen is byte-identical for a known and an unknown address",
         %{conn: conn} do
      user = user_fixture()
      unknown = unique_user_email()
      budget = ConsensusWeb.UserLive.Login.max_sends()

      refuse = fn address ->
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")
        form(lv, "#login_form_magic", user: %{email: address}) |> render_submit()
        for _ <- 2..budget, do: render_click(lv, "resend_magic")
        render_click(lv, "edit_email")
        form(lv, "#login_form_magic", user: %{email: address}) |> render_submit()
      end

      known_html = refuse.(user.email)
      unknown_html = refuse.(unknown)

      assert known_html =~ "magic-link-not-sent"

      assert String.replace(known_html, user.email, "ADDRESS") ==
               String.replace(unknown_html, unknown, "ADDRESS")
    end

    # Item 2: the exhausted *sent* screen used to instruct a press it had just removed —
    # `#magic-link-resend-exhausted` saying "that's the last one" directly under a fallback
    # paragraph still ending "send it again, or use a different address".
    test "the exhausted sent screen never points at the resend button it has removed",
         %{conn: conn} do
      user = user_fixture()
      budget = ConsensusWeb.UserLive.Login.max_sends()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      html = form(lv, "#login_form_magic", user: %{email: user.email}) |> render_submit()
      assert html =~ "send it again"

      html = Enum.reduce(2..budget, html, fn _, _ -> render_click(lv, "resend_magic") end)

      assert has_element?(lv, "#magic-link-sent")
      refute has_element?(lv, "button[phx-click='resend_magic']")
      assert has_element?(lv, "#magic-link-resend-exhausted")
      refute html =~ "send it again"
    end
  end

  defp login_token_count do
    Consensus.Repo.all(Consensus.Accounts.UserToken) |> Enum.count(&(&1.context == "login"))
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{login: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{login: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email/username or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "after a failed password log-in" do
    # The generator flashes `:email` and refills both forms from it. This app's password
    # field is `login` (email OR username), so the flash key changed — and a blanked
    # field after a wrong password is a real regression, so pin the refill itself.
    defp reload_login_page(conn) do
      assert redirected_to(conn) == ~p"/users/log-in"
      {:ok, _lv, html} = conn |> get(~p"/users/log-in") |> live()
      html
    end

    test "a typed email address comes back in both forms", %{conn: conn} do
      html =
        conn
        |> post(~p"/users/log-in", %{
          "user" => %{"login" => "typed@example.com", "password" => "wrong"}
        })
        |> reload_login_page()

      assert html =~
               ~s(<input type="text" name="user[login]" id="login_form_password_login" value="typed@example.com")

      # An address is a valid magic-link target too, so it refills that form as well —
      # this is the half the generator gave for free.
      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="typed@example.com")
    end

    test "a typed username comes back only in the password form", %{conn: conn} do
      html =
        conn
        |> post(~p"/users/log-in", %{
          "user" => %{"login" => "somebody", "password" => "wrong"}
        })
        |> reload_login_page()

      assert html =~
               ~s(<input type="text" name="user[login]" id="login_form_password_login" value="somebody")

      # `type="email"` would reject it on submit, so it must not be planted there.
      refute html =~ ~s(id="login_form_magic_email" value="somebody")
    end

    test "an over-long identifier is truncated before it reaches the flash", %{conn: conn} do
      html =
        conn
        |> post(~p"/users/log-in", %{
          "user" => %{"login" => String.duplicate("a", 300), "password" => "wrong"}
        })
        |> reload_login_page()

      assert html =~ ~s(value="#{String.duplicate("a", 160)}")
      refute html =~ ~s(value="#{String.duplicate("a", 161)}")
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"
      assert html =~ "Send magic link"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")
    end

    # D-045. The promise and the field that keeps it must live in the same form. The first
    # cut put the promise in the shared header paragraph directly above the *magic-link*
    # form — the one form on the page that carries no `return_to` — so a reader who took it
    # at its word tapped the tangerine primary action and landed on `signed_in_path/1`.
    test "the return-trip promise renders inside the password form, not above the magic-link one",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in?#{[return_to: ~p"/admin/users"]}")

      assert html =~ "Logging in with your password brings you straight back to where you were."
      refute html =~ "Logging in below brings you straight back"

      [_before_password, after_password] =
        String.split(html, ~s(id="login_form_password"), parts: 2)

      assert after_password =~
               "Logging in with your password brings you straight back to where you were."

      assert after_password =~ ~s(name="user[return_to]")

      # And the magic-link form says what it can and cannot do, rather than saying nothing
      # under a promise it does not keep.
      assert html =~ "A magic link signs you in wherever you open it"
    end

    test "no promise at all without a return_to", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      refute html =~ "brings you straight back"
      refute html =~ "A magic link signs you in wherever you open it"
      refute html =~ ~s(name="user[return_to]")
    end
  end
end
