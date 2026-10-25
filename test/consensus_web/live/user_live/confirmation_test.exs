defmodule ConsensusWeb.UserLive.ConfirmationTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  alias Consensus.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  # D-058: a magic link is a URL anyone can forward, so it never claims this browser's
  # accountless sessions without an explicit, unticked-by-default consent.
  describe "the consent to save this browser's sessions" do
    import Consensus.ActivitiesFixtures

    alias Consensus.Accounts.Scope

    test "is offered, unticked, naming the count and the account", %{
      conn: conn,
      confirmed_user: user
    } do
      {raw_token, organizer} = anonymous_organizer_fixture()
      scope = Scope.for_anonymous_organizer(organizer)
      group_fixture(scope)
      group_fixture(scope)
      {token, _hashed} = generate_user_magic_link_token(user)

      {:ok, lv, html} = conn |> put_organizer_token(raw_token) |> live(~p"/users/log-in/#{token}")

      assert html =~ "Also save the 2 sessions started in this browser to #{user.email}"

      assert has_element?(
               lv,
               "#login_form #claim-consent input[type=checkbox][name='user[claim]']"
             )

      refute has_element?(lv, "#claim-consent input[type=checkbox][checked]")
    end

    test "rides along on the confirmation form too", %{conn: conn, unconfirmed_user: user} do
      {raw_token, organizer} = anonymous_organizer_fixture()
      group_fixture(Scope.for_anonymous_organizer(organizer))
      {token, _hashed} = generate_user_magic_link_token(user)

      {:ok, lv, html} = conn |> put_organizer_token(raw_token) |> live(~p"/users/log-in/#{token}")

      assert html =~ "Also save the 1 session started in this browser"
      assert has_element?(lv, "#confirmation_form #claim-consent")
    end

    test "a ticked box survives the trigger-action round trip", %{
      conn: conn,
      confirmed_user: user
    } do
      {raw_token, organizer} = anonymous_organizer_fixture()
      group_fixture(Scope.for_anonymous_organizer(organizer))
      {token, _hashed} = generate_user_magic_link_token(user)

      {:ok, lv, _html} =
        conn |> put_organizer_token(raw_token) |> live(~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token, "claim" => "true"}})
      render_submit(form)

      assert has_element?(lv, "#claim-consent input[type=checkbox][checked]")
    end

    test "is not offered when the browser has nothing to save", %{
      conn: conn,
      confirmed_user: user
    } do
      {raw_token, _organizer} = anonymous_organizer_fixture()
      {token, _hashed} = generate_user_magic_link_token(user)

      {:ok, lv, _html} =
        conn |> put_organizer_token(raw_token) |> live(~p"/users/log-in/#{token}")

      refute has_element?(lv, "#claim-consent")

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")
      refute has_element?(lv, "#claim-consent")
    end
  end

  describe "Confirm user" do
    test "renders confirmation page for a signed-in unconfirmed user", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/users/log-in/#{token}")
      assert html =~ "Confirm and stay logged in"

      # The warning must be accurate for *every* case that clears the password, and
      # being signed in as the account is no longer an exception.
      assert html =~ "confirming here will remove it"
    end

    test "renders login page for confirmed user", %{conn: conn, confirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "an organizer cookie keeps the remember-me choice (D-058)", %{
      conn: conn,
      confirmed_user: user
    } do
      # An organizer with no account opening their magic link: their identity is a truthy
      # `%Scope{user: nil}` inside the wizard, and reading it as "signed in" here would
      # swap the two remember-me buttons for the signed-in bare "Log in".
      %{conn: conn} = create_anonymous_organizer(%{conn: conn})

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")

      assert html =~ "Keep me logged in on this device"
      assert html =~ "Log me in only this time"
      assert has_element?(lv, ~s|#login_form button[name="user[remember_me]"]|)
    end

    test "renders login page for already logged in user", %{conn: conn, confirmed_user: user} do
      conn = log_in_user(conn, user)

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "warns a signed-out visitor that confirming will discard the existing password", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")

      assert html =~ "confirming here will remove it"
      # The button is still offered — this is the recovery path, not a dead end.
      assert html =~ "Confirm and stay logged in"
      refute Accounts.get_user!(user.id).confirmed_at
    end

    test "confirming from a signed-out session clears the password and says so", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "password"
      assert get_session(conn, :user_token)

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.confirmed_at
      assert is_nil(reloaded.hashed_password)
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      # Signed in as that user or not, confirming an account that holds a password
      # discards it. See `Accounts.login_user_by_magic_link/1`.
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "The password that was set on this account has been removed"

      assert Accounts.get_user!(user.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/settings"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed user in without changing confirmed_at", %{
      conn: conn,
      confirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end
end
