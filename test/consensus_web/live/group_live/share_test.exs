defmodule ConsensusWeb.GroupLive.ShareTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities

  setup :register_and_log_in_user

  describe "a published group" do
    setup %{scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      %{group: group}
    end

    test "renders the slug-based join url, the organizer's username and the option count", %{
      conn: conn,
      group: group,
      user: user
    } do
      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/share")

      assert html =~ "/join/#{group.slug}"
      assert html =~ user.username
      assert html =~ group.title
      assert html =~ "2 spots"
    end

    test "raises for another user's group", %{group: group} do
      stranger_conn = Phoenix.ConnTest.build_conn() |> log_in_user(user_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(stranger_conn, ~p"/groups/#{group}/share")
      end
    end
  end

  describe "a draft group" do
    test "is redirected back to review — there is no live link yet", %{conn: conn, scope: scope} do
      group = group_fixture(scope)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/groups/#{group}/share")
      assert to == ~p"/groups/#{group}/review"
    end
  end
end
