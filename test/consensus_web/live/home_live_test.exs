defmodule ConsensusWeb.HomeLiveTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.ActivitiesFixtures
  import Consensus.AccountsFixtures

  alias Consensus.Activities

  describe "signed out" do
    test "renders the splash headline and a register link", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Decide"

      assert lv
             |> element(~s|a[href="#{~p"/users/register"}"]|, "Get started")
             |> has_element?()
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
  end
end
