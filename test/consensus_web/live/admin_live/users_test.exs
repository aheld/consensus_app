defmodule ConsensusWeb.AdminLive.UsersTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import ExUnit.CaptureLog

  alias Consensus.Accounts

  # The application produces a stale session by ageing the *token*: `UserAuth` stamps
  # `authenticated_at` onto the user from the session token on every request and on every
  # LiveView mount, so backdating a `%Scope{}` struct would be overwritten before the
  # LiveView ever saw it. A day is far outside the 20-minute window
  # `Accounts.sudo_mode?/2` enforces.
  defp stale_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> log_in_user(user,
      token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
    )
  end

  # Refusing has to be a *bounce*, not a bare error: the operator is a real admin whose
  # session merely went cold, so they are sent to re-authenticate and told where they
  # will land. `push_navigate/2` leaves the admin `live_session`, which the test client
  # sees as a redirect carrying the flash.
  defp assert_stale_session_bounce(lv) do
    flash = assert_redirect(lv, ~p"/users/log-in")
    assert flash["error"] =~ "log in again"
    assert flash["error"] =~ "Admin"
  end

  # The `[audit]` tag is what an operator greps for, so it is pinned. Everything after it
  # is returned with Logger's own timestamp/level prefix stripped, so that assertions on
  # ids cannot be satisfied by a digit that happens to appear in the timestamp.
  defp audit_lines(log) do
    log
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, "[audit]", parts: 2) do
        [_prefix, message] -> [String.trim(message)]
        _ -> []
      end
    end)
  end

  describe "authorization" do
    test "redirects an anonymous visitor to the log-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(conn, ~p"/admin/users")

      assert to == ~p"/users/log-in"
      assert flash["error"] =~ "must log in"
    end

    test "redirects a signed-in member home", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(conn, ~p"/admin/users")
      assert to == ~p"/"
      assert flash["error"] =~ "do not have access"
    end

    test "a member cannot reach the admin area over plain HTTP either", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/admin/users")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "do not have access"
    end

    test "a member cannot reach the LiveDashboard", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/admin/dashboard")
      assert redirected_to(conn) == ~p"/"
    end

    test "an admin can reach the LiveDashboard", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get(~p"/admin/dashboard")
      assert redirected_to(conn) =~ "/admin/dashboard/"
    end

    test "/admin resolves to the users page for an admin", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(admin_fixture()) |> live(~p"/admin")
      assert html =~ "Users"
    end
  end

  describe "listing" do
    setup %{conn: conn} do
      admin = admin_fixture(%{username: "rootadmin"})
      member = user_fixture(%{username: "plainmember"})
      %{conn: log_in_user(conn, admin), admin: admin, member: member}
    end

    test "shows every account with its role", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "rootadmin"
      assert html =~ "plainmember"
      assert html =~ "admin"
      assert html =~ "member"
    end

    test "marks which row is you", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")
      assert html =~ "you"
    end
  end

  describe "promoting and demoting" do
    setup %{conn: conn} do
      admin = admin_fixture(%{username: "rootadmin"})
      member = user_fixture(%{username: "plainmember"})
      %{conn: log_in_user(conn, admin), admin: admin, member: member}
    end

    test "promotes a member", %{conn: conn, member: member} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> element(~s|button[phx-value-id="#{member.id}"][phx-value-admin="true"]|)
        |> render_click()

      assert html =~ "plainmember is now an admin"
      assert Accounts.get_user!(member.id).is_admin
    end

    test "demotes an admin once someone else holds the role", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      {:ok, {member, _}} =
        Accounts.set_admin(user_scope_fixture(admin), member, true)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> element(~s|button[phx-value-id="#{member.id}"][phx-value-admin="false"]|)
        |> render_click()

      assert html =~ "plainmember is no longer an admin"
      refute Accounts.get_user!(member.id).is_admin
    end

    test "survives hostile set_admin payloads", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      for payload <- [
            %{"id" => "not-a-number", "admin" => "true"},
            %{"id" => "999999", "admin" => "true"},
            %{"id" => "-1", "admin" => "true"},
            %{"id" => "0", "admin" => "true"},
            %{"id" => String.duplicate("9", 26), "admin" => "true"},
            %{"id" => "1"},
            %{}
          ] do
        assert render_click(lv, "set_admin", payload) =~ "Could not"
        assert Process.alive?(lv.pid)
      end
    end

    test "a demoted admin cannot keep acting from a page they already had open", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      # Promote the member, then let them open the admin page.
      {:ok, {member, _}} = Accounts.set_admin(user_scope_fixture(admin), member, true)
      member_conn = build_conn() |> log_in_user(member)
      {:ok, member_lv, _html} = live(member_conn, ~p"/admin/users")

      # The original admin demotes them while that page is still mounted.
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv
      |> element(~s|button[phx-value-id="#{member.id}"][phx-value-admin="false"]|)
      |> render_click()

      refute Accounts.get_user!(member.id).is_admin

      # Their stale page must not still be able to hand out the role.
      target = Consensus.AccountsFixtures.user_fixture()
      render_click(member_lv, "set_admin", %{"id" => to_string(target.id), "admin" => "true"})

      refute Accounts.get_user!(target.id).is_admin
    end

    test "demoting severs the demoted admin's live sockets", %{conn: conn} do
      # The context re-reads the actor, so a stale page cannot *write* (see the test
      # above). Nothing in the context can protect LiveDashboard: it is third-party,
      # its only guard is the `:require_admin` on_mount hook, and that hook runs once
      # at mount — `live_patch` between dashboard pages inside the same live_session
      # does not remount. The single `disconnect_sessions/1` call in AdminLive.Users is
      # therefore the entire revocation mechanism for the most privileged surface in
      # the app. Assert the broadcast it emits: `Phoenix.LiveViewTest` has no real
      # socket transport, so the disconnect it triggers cannot be observed any other way.
      victim = admin_fixture(%{username: "demotedadmin"})
      token = Accounts.generate_user_session_token(victim)
      topic = "users_sessions:#{Base.url_encode64(token)}"
      ConsensusWeb.Endpoint.subscribe(topic)

      victim_conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token)

      {:ok, victim_lv, _html} = live(victim_conn, ~p"/admin/users")
      assert Process.alive?(victim_lv.pid)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv
      |> element(~s|button[phx-value-id="#{victim.id}"][phx-value-admin="false"]|)
      |> render_click()

      refute Accounts.get_user!(victim.id).is_admin

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}, 500

      # The session token deliberately survives — they stay signed in as a member — so
      # what makes the disconnect a revocation is that the forced remount re-runs the
      # hook and now fails it.
      assert {:error, {:redirect, %{to: to}}} = live(victim_conn, ~p"/admin/users")
      assert to == ~p"/"
    end

    test "deletes a member", %{conn: conn, member: member} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> element(~s|button[phx-click="delete_user"][phx-value-id="#{member.id}"]|)
        |> render_click()

      assert html =~ "plainmember was deleted"
      refute Accounts.get_user(member.id)
    end

    test "offers no delete button for an admin or for yourself", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      {:ok, {_member, _}} = Accounts.set_admin(user_scope_fixture(admin), member, true)
      {:ok, lv, html} = live(conn, ~p"/admin/users")

      refute html =~ ~s|phx-value-id="#{admin.id}"| |> String.replace("phx-value-id", "delete")
      assert lv |> element(~s|button[phx-click="delete_user"]|) |> has_element?() == false
    end

    test "the server refuses a delete the UI does not offer", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert render_click(lv, "delete_user", %{"id" => to_string(admin.id)}) =~
               "cannot delete your own account"

      assert Accounts.get_user(admin.id)
    end

    test "survives hostile delete_user payloads", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      for payload <- [%{"id" => "nope"}, %{"id" => "999999"}, %{}] do
        assert render_click(lv, "delete_user", payload) =~ "Could not"
        assert Process.alive?(lv.pid)
      end
    end

    test "refuses to remove the last admin", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # The button is disabled in the UI, so drive the event directly — the server
      # must refuse regardless of what the client sends.
      html = render_click(lv, "set_admin", %{"id" => to_string(admin.id), "admin" => "false"})

      assert html =~ "cannot remove the last admin"
      assert Accounts.get_user!(admin.id).is_admin
    end

    test "answers cleanly when the client sends a bogus user id", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert render_click(lv, "set_admin", %{"id" => "not-a-number", "admin" => "true"}) =~
               "Could not find that user"

      assert render_click(lv, "set_admin", %{"id" => "999999", "admin" => "true"}) =~
               "Could not find that user"
    end

    test "the demote button is disabled while there is only one admin", %{
      conn: conn,
      admin: admin
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert lv
             |> element(~s|button[phx-value-id="#{admin.id}"][phx-value-admin="false"]|)
             |> render() =~ "disabled"
    end

    test "an id with trailing garbage is rejected, not truncated to a real account", %{
      conn: conn,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # `Integer.parse("#{id}abc")` returns `{id, "abc"}`. Matching on `{user_id, ""}` is
      # the only thing that makes that a miss: relaxing it to `{user_id, _}` would let a
      # client address any account by numeric prefix, and every other test in this file
      # would still pass. Both handlers parse, so both are pinned.
      for suffix <- ["abc", " ", ".9", "\n", "]"] do
        id = "#{member.id}#{suffix}"

        assert render_click(lv, "set_admin", %{"id" => id, "admin" => "true"}) =~
                 "Could not find that user"

        refute Accounts.get_user!(member.id).is_admin

        assert render_click(lv, "delete_user", %{"id" => id}) =~ "Could not find that user"
        assert Accounts.get_user(member.id)
      end

      # A leading sign parses too, and would otherwise resolve to the same row.
      assert render_click(lv, "set_admin", %{"id" => "+#{member.id}x", "admin" => "true"}) =~
               "Could not find that user"

      refute Accounts.get_user!(member.id).is_admin
    end

    test "deleting severs the deleted account's live sockets", %{conn: conn} do
      # `Accounts.delete_user/2` takes the session rows out with the user via
      # `ON DELETE CASCADE`, but a LiveView the deleted person already has mounted keeps
      # running on a scope with no account behind it until something forces a remount.
      # The `disconnect_sessions/1` call in the delete branch is what forces it, and
      # `Phoenix.LiveViewTest` has no real socket transport, so the broadcast is the only
      # observable evidence that the call is still there.
      victim = user_fixture(%{username: "doomeduser"})
      token = Accounts.generate_user_session_token(victim)
      topic = "users_sessions:#{Base.url_encode64(token)}"
      ConsensusWeb.Endpoint.subscribe(topic)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> element(~s|button[phx-click="delete_user"][phx-value-id="#{victim.id}"]|)
        |> render_click()

      assert html =~ "doomeduser was deleted"
      refute Accounts.get_user(victim.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}, 500
    end
  end

  describe "a session that is authenticated but no longer fresh" do
    # Every refusal here writes an `[audit] ... REFUSED` warning, which is the point —
    # but it is noise in the suite's output.
    @describetag :capture_log

    setup %{conn: _conn} do
      admin = admin_fixture(%{username: "staleadmin"})
      coadmin = admin_fixture(%{username: "coadmin"})
      member = user_fixture(%{username: "plainmember"})

      %{conn: stale_conn(admin), admin: admin, coadmin: coadmin, member: member}
    end

    test "Promote sends them back to log in instead of granting the role", %{
      conn: conn,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "set_admin", %{"id" => to_string(member.id), "admin" => "true"})

      assert_stale_session_bounce(lv)
      refute Accounts.get_user!(member.id).is_admin
    end

    test "Demote sends them back to log in instead of revoking the role", %{
      conn: conn,
      coadmin: coadmin
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "set_admin", %{"id" => to_string(coadmin.id), "admin" => "false"})

      assert_stale_session_bounce(lv)
      assert Accounts.get_user!(coadmin.id).is_admin
    end

    test "Delete sends them back to log in instead of destroying the account", %{
      conn: conn,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "delete_user", %{"id" => to_string(member.id)})

      assert_stale_session_bounce(lv)
      assert Accounts.get_user(member.id)
    end

    test "the page says so and disables the three controls", %{
      conn: conn,
      coadmin: coadmin,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # A disabled button is not focusable, so its `title` never reaches a keyboard or
      # screen-reader user. The standing notice is the accessible half of the
      # explanation and is asserted on its own element, not on the page as a whole —
      # otherwise the button titles would satisfy the assertion and deleting the notice
      # would go unnoticed.
      assert lv |> element("#sudo-notice") |> render() =~
               "log in again to change roles or delete accounts"

      for selector <- [
            ~s|button[phx-value-id="#{member.id}"][phx-value-admin="true"]|,
            ~s|button[phx-value-id="#{coadmin.id}"][phx-value-admin="false"]|,
            ~s|button[phx-click="delete_user"][phx-value-id="#{member.id}"]|
          ] do
        rendered = lv |> element(selector) |> render()

        assert rendered =~ "disabled"
        assert rendered =~ "log in again to change roles or delete accounts"
      end
    end

    test "a forged event is still refused when the buttons are disabled", %{
      conn: conn,
      member: member
    } do
      # The `disabled` attributes above are a courtesy to the operator. A client that
      # ignores them — or a replayed event from another tab — must still be turned away
      # by the context, which is where the real check lives.
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "set_admin", %{"id" => to_string(member.id), "admin" => "true"})
      refute Accounts.get_user!(member.id).is_admin

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "delete_user", %{"id" => to_string(member.id)})
      assert Accounts.get_user(member.id)
    end

    test "a fresh session is not disabled, so the notice is about freshness alone", %{
      admin: admin,
      member: member
    } do
      {:ok, lv, html} =
        Phoenix.ConnTest.build_conn() |> log_in_user(admin) |> live(~p"/admin/users")

      refute html =~ "log in again to change roles or delete accounts"

      refute lv
             |> element(~s|button[phx-value-id="#{member.id}"][phx-value-admin="true"]|)
             |> render() =~ "disabled"
    end
  end

  describe "the audit log" do
    setup %{conn: conn} do
      admin = admin_fixture(%{username: "rootadmin"})
      member = user_fixture(%{username: "plainmember"})

      # `config/test.exs` pins Logger at :warning and the success line is :info, which
      # `capture_log/2` cannot raise on its own. `ConnCase` is synchronous, so no other
      # module is running while this one changes the global level.
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      %{conn: log_in_user(conn, admin), admin: admin, member: member}
    end

    test "a successful promotion records who did it and to whom", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      # One machine, no external audit sink, no undo: this line is the only record of who
      # handed out the admin role. Assert the facts — the action, both ids — rather than
      # the punctuation, so the format can be reworded without breaking the test.
      log =
        capture_log(fn ->
          {:ok, lv, _html} = live(conn, ~p"/admin/users")

          lv
          |> element(~s|button[phx-value-id="#{member.id}"][phx-value-admin="true"]|)
          |> render_click()
        end)

      assert [line] = audit_lines(log)
      assert line =~ "grant_admin"
      assert line =~ ~r/\b#{admin.id}\b/
      assert line =~ ~r/\b#{member.id}\b/
      refute line =~ "REFUSED"

      assert Accounts.get_user!(member.id).is_admin
    end

    test "a refusal is recorded as loudly as a success", %{admin: admin, member: member} do
      # A burst of refusals is what an attempt to use a stale or revoked session looks
      # like from the outside, so it has to be in the log too.
      log =
        capture_log(fn ->
          {:ok, lv, _html} = live(stale_conn(admin), ~p"/admin/users")
          render_click(lv, "set_admin", %{"id" => to_string(member.id), "admin" => "true"})
        end)

      assert [line] = audit_lines(log)
      assert line =~ "REFUSED"
      assert line =~ "grant_admin"
      assert line =~ ~r/\b#{admin.id}\b/
      assert line =~ ~r/\b#{member.id}\b/

      refute Accounts.get_user!(member.id).is_admin
    end
  end

  describe "the default-password warning" do
    @describetag :capture_log

    test "appears while the seeded admin still has the default password", %{conn: conn} do
      {:ok, %{admin: admin}} = Consensus.Seeds.run!()

      {:ok, _lv, html} = conn |> log_in_user(admin) |> live(~p"/admin/users")

      assert html =~ "still using the default password"
    end

    test "goes away once the password is changed", %{conn: conn} do
      {:ok, %{admin: admin}} = Consensus.Seeds.run!()
      {:ok, {admin, _}} = Accounts.update_user_password(admin, %{password: "a much longer one"})

      {:ok, _lv, html} = conn |> log_in_user(admin) |> live(~p"/admin/users")

      refute html =~ "still using the default password"
    end
  end
end
