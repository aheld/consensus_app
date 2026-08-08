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

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
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

      {:ok, _lv, html} =
        lv
        |> form("#registration_form", user: %{"email" => email, "username" => username})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "We sent a sign-in link to #{email}"

      user = Accounts.get_user_by_username(username)
      assert user.email == email
      refute user.confirmed_at

      assert Consensus.Repo.get_by!(Consensus.Accounts.UserToken, user_id: user.id).context ==
               "login"
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
end
