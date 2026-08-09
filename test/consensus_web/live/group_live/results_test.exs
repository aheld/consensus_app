defmodule ConsensusWeb.GroupLive.ResultsTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting

  setup :register_and_log_in_user

  describe "mount" do
    test "raises for another user's group", %{conn: conn} do
      owner_scope = user_scope_fixture()
      group = group_fixture(owner_scope)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/groups/#{group}/results")
      end
    end

    test "a :draft group redirects to the review screen — nothing has published yet",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/groups/#{group}/results")
      assert to == ~p"/groups/#{group}/review"
    end
  end

  describe "rendering an open (:voting) group" do
    test "shows the countdown header, avatar row, running tally and organizer footer",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant_fixture(group, %{display_name: "Ada"})

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ group.title
      assert html =~ "LIVE"
      assert html =~ "Running tally"
      assert html =~ a.name
      assert html =~ "0/1 voted"
      assert html =~ "Nudge"
      assert html =~ "Close now"
      assert html =~ "Anonymous session"
    end

    test "a vetoed option renders struck-through with the VETOED pill, not a winner card",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [], a.id)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Vetoed"
      refute html =~ "We have a winner"
    end
  end

  describe "live updates — the acceptance bar" do
    test "a ballot cast in a second session appears without this session navigating",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "0/1 voted" || html =~ "0/0 voted"

      participant = participant_fixture(group, %{display_name: "Guest"})
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])

      # Force this test to wait for the already-processed :ballot_cast broadcast
      # before asserting, instead of sleeping (AGENTS.md).
      _ = :sys.get_state(lv.pid)
      html = render(lv)

      assert html =~ "1/1 voted"
    end

    test "a guest joining (not yet voting) in a second session appears without this session navigating",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope, 2)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "0/0 voted"

      participant_fixture(group, %{display_name: "Guest"})

      # Force this test to wait for the already-processed :participant_joined broadcast
      # before asserting, instead of sleeping (AGENTS.md).
      _ = :sys.get_state(lv.pid)
      html = render(lv)

      assert html =~ "0/1 voted"
    end
  end

  describe "close_now" do
    test "closes the vote and the shared panel announces the winner",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")
      html = lv |> element("button", "Close now") |> render_click()

      assert html =~ "We have a winner"
      assert html =~ a.name
      assert html =~ "Voting closed"
      refute html =~ "Nudge"
      assert Activities.get_group!(scope, group.id).status == :completed
    end

    test "refuses on an already-finished group and the footer offers nothing to click",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")
      refute html =~ "Close now"
      refute html =~ "Nudge"
    end
  end

  describe "nudge" do
    test "flashes a confirmation without pretending to send anything",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")
      html = lv |> element("button", "Nudge") |> render_click()

      assert html =~ "no notification system"
    end
  end

  describe "outcomes on a finished group" do
    test "everyone vetoing everything is reported honestly, not as an empty winner card",
         %{conn: conn, scope: scope} do
      {group, [a]} = voting_group_fixture(scope, 1)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "no consensus"
      refute html =~ "We have a winner"
    end

    test "a cancelled group shows a cancelled notice, not a winner", %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.cancel_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "cancelled"
      refute html =~ "We have a winner"
    end

    test "the winner card links out to the winning option's own source_url",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      a = activity_fixture(group, %{source_url: "https://example.com/booking"})
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "https://example.com/booking"
      assert html =~ "copy-summary"
    end
  end
end
