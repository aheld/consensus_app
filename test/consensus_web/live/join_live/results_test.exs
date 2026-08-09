defmodule ConsensusWeb.JoinLive.ResultsTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  defp with_participant(conn, group, participant) do
    conn
    |> init_test_session(%{})
    |> put_session(JoinAuth.participant_session_key(group.id), participant.token)
  end

  describe "before this browser has voted" do
    test "shows a Cast your vote CTA, not the locked notice or the ranking banner",
         %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)
      conn = with_participant(conn, group, participant)

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "Cast your vote"
      refute html =~ "Your ranking is in"
      refute html =~ "can nudge or close early"
    end

    test "still renders for a visitor with no participant at all (a direct link)",
         %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "Cast your vote"
      assert html =~ group.title
    end
  end

  describe "after this browser has voted" do
    test "shows the locked confirmation and the organizer notice — never 'change my ranking'",
         %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      conn = with_participant(conn, group, participant)

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "Your ranking is in"
      assert html =~ "can nudge or close early"
      assert html =~ scope.user.username
      refute html =~ "Change my ranking"
      refute html =~ "Cast your vote"
    end
  end

  describe "live updates — a guest's own session sees the tally move" do
    test "a second participant's ballot appears without navigating", %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      conn = with_participant(conn, group, participant)

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}/results")

      other = participant_fixture(group, %{display_name: "Other"})
      {:ok, _other} = Voting.cast_ballot(other, [a.id])

      _ = :sys.get_state(lv.pid)
      html = render(lv)

      assert html =~ "1/2 voted"
    end
  end

  describe "a completed group" do
    test "announces the winner and offers the copy-to-clipboard summary", %{conn: conn} do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      a = activity_fixture(group, %{source_url: "https://example.com/booking"})
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.complete_group(scope, group)
      conn = with_participant(conn, group, participant)

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "We have a winner"
      assert html =~ a.name
      assert html =~ "https://example.com/booking"
      refute html =~ "Change my ranking"
    end

    test "no consensus is reported honestly", %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a]} = voting_group_fixture(scope, 1)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)
      conn = with_participant(conn, group, participant)

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "no consensus"
      refute html =~ "We have a winner"
    end
  end

  describe "a cancelled group" do
    test "shows a cancelled notice instead of the locked-vote notice", %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.cancel_group(scope, group)
      conn = with_participant(conn, group, participant)

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "cancelled"
      refute html =~ "can nudge or close early"
      refute html =~ "We have a winner"
    end
  end
end
