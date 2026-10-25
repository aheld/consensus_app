defmodule ConsensusWeb.HomeLiveTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.ActivitiesFixtures
  import Consensus.AccountsFixtures

  alias Consensus.Activities

  describe "signed out" do
    test "renders the splash headline and a Start something straight into the wizard", %{
      conn: conn
    } do
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Decide"

      # D-058: organizing needs no account, so the front door's forward action is the
      # wizard itself, not registration.
      assert has_element?(lv, ~s|#home-start[href="#{~p"/groups/new"}"]|, "Start something")
      refute has_element?(lv, ~s|a[href="#{~p"/users/register"}"]|, "Start something")
    end
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "renders a group title and its status pill", %{conn: conn, scope: scope} do
      group_fixture(scope, %{title: "Dinner Friday?"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert render(lv) =~ "Dinner Friday?"
      assert lv |> element("span", "DRAFT") |> has_element?()
    end

    test "a draft with no options links back into the wizard's edit step", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, %{title: "Bowling night"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert lv
             |> element(~s|a[href="#{~p"/groups/#{group.id}/edit"}"]|, "Bowling night")
             |> has_element?()
    end

    test "a draft with options links into the options step", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{title: "Bowling night"})
      activity_fixture(group)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert lv
             |> element(~s|a[href="#{~p"/groups/#{group.id}/options"}"]|, "Bowling night")
             |> has_element?()
    end

    test "a voting group links to live results and shows the VOTING pill", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, %{title: "Dinner Friday?", deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert lv
             |> element(~s|a[href="#{~p"/groups/#{group.id}/results"}"]|, "Dinner Friday?")
             |> has_element?()

      assert lv |> element("span", "VOTING") |> has_element?()
    end

    test "renders the empty state when the organizer has no groups", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert render(lv) =~ "Nothing yet. Start something above."
    end

    test "an account's list carries no 'only in this browser' line", %{conn: conn, scope: scope} do
      group_fixture(scope, %{title: "Saved already"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#home-sessions")
      refute has_element?(lv, "#home-unsaved")
    end

    test "another user's group does not appear", %{conn: conn} do
      other_scope = user_scope_fixture()
      group_fixture(other_scope, %{title: "Someone else's plan"})

      {:ok, lv, _html} = live(conn, ~p"/")

      refute render(lv) =~ "Someone else's plan"
    end

    test "a subscribe_group broadcast updates the rendered list without a navigation", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, %{title: "Original title"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert render(lv) =~ "Original title"

      {:ok, _updated} = Activities.update_group(scope, group, %{title: "Renamed plan"})

      # Same connected LiveView process the whole time — if this were a navigation the
      # `live/2` call above would have returned a different view or this render would 404.
      assert render(lv) =~ "Renamed plan"
      refute render(lv) =~ "Original title"
    end

    test "survives the voting broadcasts that share the group's topic", %{
      conn: conn,
      scope: scope
    } do
      # `Consensus.Voting` publishes on `Activities.topic/1`, the same topic this screen
      # subscribes to, so an organizer sitting on `/` receives every join and every
      # ballot on their live groups. Before this test the LiveView had no matching
      # `handle_info/2` head and terminated with a `FunctionClauseError` the moment
      # anybody voted — observed in a browser, invisible to the suite.
      group = group_fixture(scope, %{title: "Broadcast target"})

      {:ok, lv, _html} = live(conn, ~p"/")

      for message <- [{:participant_joined, group.id}, {:ballot_cast, group.id}] do
        Phoenix.PubSub.broadcast(Consensus.PubSub, Activities.topic(group.id), message)
        assert render(lv) =~ "Broadcast target"
      end
    end
  end

  describe "an organizer with no account, first visit (D-058)" do
    test "a drive-by visit to /groups/new and back still lands on the splash", %{conn: conn} do
      # The cookieless first visit mints an identity — but one that owns nothing, so `‹`
      # back to `/` must show the `00a` splash with `:marketing` chrome, not an empty
      # "Your sessions" for somebody who has made nothing.
      conn = get(conn, ~p"/groups/new")
      assert html_response(conn, 200)
      assert conn.resp_cookies[ConsensusWeb.OrganizerAuth.cookie_name()], "nothing was minted"

      conn = conn |> recycle() |> get(~p"/")
      html = html_response(conn, 200)

      assert html =~ ~s(id="home-hero")
      refute html =~ ~s(id="home-sessions")
      assert html =~ ~s(id="chrome-sign-in")
      refute html =~ ~s(id="chrome-menu")
      assert html =~ "Decide together · Consensus</title>"

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#home-hero")
      refute has_element?(lv, "#home-sessions")
    end
  end

  describe "an organizer with no account, holding an identity (D-058)" do
    setup :create_anonymous_organizer

    test "with no session yet, the splash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#home-hero")
      refute has_element?(lv, "#home-sessions")
    end

    test "once they own a session, the list with :app chrome", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{title: "Taco Tuesday"})

      {:ok, lv, html} = live(conn, ~p"/")

      assert has_element?(lv, "#home-sessions")
      refute has_element?(lv, "#home-hero")
      assert html =~ "Your sessions · Consensus</title>"
      assert has_element?(lv, "#chrome-menu")
      refute has_element?(lv, "#chrome-sign-in")

      assert lv
             |> element(~s|a[href="#{~p"/groups/#{group.id}/edit"}"]|, "Taco Tuesday")
             |> has_element?()
    end

    test "the list says it lives only in this browser, with a door to save it", %{
      conn: conn,
      scope: scope
    } do
      # Plan §7.1's quiet `00` line: nothing but this browser's organizer cookie holds
      # these sessions until an account claims them.
      group_fixture(scope, %{title: "Taco Tuesday"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#home-unsaved", "Only in this browser")

      assert has_element?(
               lv,
               ~s|#home-unsaved-register[href="#{~p"/users/register"}"]|,
               "save these"
             )
    end

    test "sees only its own sessions", %{conn: conn, scope: scope} do
      group_fixture(scope, %{title: "Mine"})
      {_other, _group} = anonymous_group_fixture(%{title: "Another browser's plan"})
      group_fixture(user_scope_fixture(), %{title: "An account's plan"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert render(lv) =~ "Mine"
      refute render(lv) =~ "Another browser's plan"
      refute render(lv) =~ "An account's plan"
    end

    test "the list is live for an anonymous owner too", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{title: "Original title"})

      {:ok, lv, _html} = live(conn, ~p"/")
      assert render(lv) =~ "Original title"

      {:ok, _updated} = Activities.update_group(scope, group, %{title: "Renamed plan"})

      assert render(lv) =~ "Renamed plan"
      refute render(lv) =~ "Original title"

      Phoenix.PubSub.broadcast(
        Consensus.PubSub,
        Activities.topic(group.id),
        {:ballot_cast, group.id}
      )

      assert render(lv) =~ "Renamed plan"
    end
  end
end
