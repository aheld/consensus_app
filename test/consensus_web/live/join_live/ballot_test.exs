defmodule ConsensusWeb.JoinLive.BallotTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  defp join_conn(conn, group, participant) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)
  end

  describe "mount — no participant yet" do
    test "redirects to the entry screen rather than rendering an empty ballot", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/join/#{group.slug}/vote")
      assert to == ~p"/join/#{group.slug}"
    end
  end

  describe "mount — the ballot is already locked (D-036)" do
    test "a participant with voted_at set is redirected to results, not the grid", %{conn: conn} do
      {group, activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [hd(activities).id])

      conn = join_conn(conn, group, participant)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/join/#{group.slug}/vote")
      assert to == ~p"/join/#{group.slug}/results"
    end
  end

  describe "mount — an unvoted participant" do
    setup %{conn: conn} do
      {group, activities} = voting_group_fixture(user_scope_fixture(), 3)
      participant = participant_fixture(group, %{display_name: "Ada"})
      conn = join_conn(conn, group, participant)
      %{conn: conn, group: group, activities: activities, participant: participant}
    end

    test "renders every activity in the pool with a starting count of zero", %{
      conn: conn,
      group: group,
      activities: activities
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert html =~ "happy with"

      for activity <- activities do
        assert html =~ activity.name
      end

      assert html =~ "0 PICKED"
      assert html =~ "1 VETO LEFT"
    end

    test "a missing description falls back to a plain placeholder, not a blank line", %{
      conn: conn,
      group: group
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote")
      assert html =~ "No details yet"
    end

    test "clicking a card approves it, and clicking again un-approves it", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "1 PICKED"
      assert has_element?(view, "button[aria-pressed='true'][phx-value-id='#{first.id}']")

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "0 PICKED"
    end

    test "a non-numeric id pushed at toggle_approve is ignored, not a crash", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = render_click(view, "toggle_approve", %{"id" => "not-an-int"})

      assert html =~ "0 PICKED"
      assert Process.alive?(view.pid)
    end

    test "a non-numeric id pushed at toggle_veto is ignored, not a crash", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = render_click(view, "toggle_veto", %{"id" => "not-an-int"})

      assert html =~ "1 VETO LEFT"
      assert Process.alive?(view.pid)
    end

    test "vetoing a card marks it VETOED and hides its meta line", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "Vetoed"
      assert html =~ "0 VETOES LEFT"
    end

    test "vetoing an already-approved card un-approves it — never both at once", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "0 PICKED"
      assert html =~ "Vetoed"
    end

    test "the server ignores a pushed approve for a card currently vetoed", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      html = render_click(view, "toggle_approve", %{"id" => to_string(first.id)})

      assert html =~ "0 PICKED"
      assert html =~ "Vetoed"
    end

    test "there is only ever one veto — vetoing a second card moves it off the first", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
        |> render_click()

      assert html =~ "0 VETOES LEFT"

      refute has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )

      assert has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{second.id}'][aria-pressed='true']"
             )
    end

    test "clicking the same veto control again removes the veto", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "1 VETO LEFT"
      refute html =~ "Vetoed"
    end

    test "the submit button is disabled until something is picked or vetoed", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")
      assert html =~ ~s(id="submit-ballot")
      assert has_element?(view, "button#submit-ballot[disabled]")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      refute has_element?(view, "button#submit-ballot[disabled]")
    end

    test "submitting with nothing picked and nothing vetoed refuses and stays put", %{
      conn: conn,
      group: group,
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = render_click(view, "submit_ballot", %{})

      assert html =~ "Pick at least one, or veto one"
      assert Voting.get_participant_by_token(participant.token).voted_at == nil
    end

    test "submitting a real ballot casts it and navigates to results", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest],
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
      |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> element("#submit-ballot")
        |> render_click()

      assert to == ~p"/join/#{group.slug}/results"

      voted = Voting.get_participant_by_token(participant.token)
      assert voted.voted_at

      tally = Voting.tally(group)
      first_row = Enum.find(tally, &(&1.activity.id == first.id))
      second_row = Enum.find(tally, &(&1.activity.id == second.id))

      assert first_row.approvals == 1
      assert second_row.vetoed?
    end

    test "re-submitting an already-locked ballot (double tab) redirects to results", %{
      conn: conn,
      group: group,
      participant: participant,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      # A second tab (or a retried request) casts the ballot first.
      {:ok, _voted} = Voting.cast_ballot(participant, [first.id])

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      # Its flash carries the "already in" message, but a `push_navigate` mid-session
      # ships the flash as an opaque signed token for the *next* mount to decode — not
      # a plain map here — so this asserts the redirect only. `handle_cast_error/3`'s
      # `:already_voted` clause (this file) is what sets that flash.
      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#submit-ballot")
               |> render_click()

      assert to == ~p"/join/#{group.slug}/results"
    end

    test "an id the client invented is refused as unknown_activity, not written", %{
      conn: conn,
      group: group,
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      render_click(view, "toggle_approve", %{"id" => "999999999"})
      html = render_click(view, "submit_ballot", %{})

      assert html =~ "Something in the pool changed"
      assert Voting.get_participant_by_token(participant.token).voted_at == nil
    end

    test "voting has closed under the voter (deadline passed) sends them to results", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      expire_deadline!(group)

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#submit-ballot")
               |> render_click()

      assert to == ~p"/join/#{group.slug}/results"
    end

    test "the group closing under the voter (organizer ends it) sends them to results", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      force_group!(group, %{status: :completed, completed_at: DateTime.utc_now(:second)})

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#submit-ballot")
               |> render_click()

      assert to == ~p"/join/#{group.slug}/results"
    end
  end

  describe "veto_allowed: false" do
    test "hides the veto affordance entirely and reports picks only", %{conn: conn} do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline(), veto_allowed: false})
      activity = activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)

      conn = join_conn(conn, group, participant)
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      refute html =~ "VETO"
      refute has_element?(view, "button[phx-click='toggle_veto']")

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{activity.id}']")
        |> render_click()

      assert html =~ "1 PICKED"
      refute html =~ "VETO"
    end

    test "a pushed veto event (bypassing the hidden UI) is still refused by the context", %{
      conn: conn
    } do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline(), veto_allowed: false})
      activity = activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)

      conn = join_conn(conn, group, participant)
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      render_click(view, "toggle_veto", %{"id" => to_string(activity.id)})
      html = render_click(view, "submit_ballot", %{})

      assert html =~ "allowed in this group"
      assert Voting.get_participant_by_token(participant.token).voted_at == nil
    end
  end
end
