defmodule ConsensusWeb.Endgame.TieTest do
  @moduledoc """
  The Tie takeover (`docs/plans/endgame-screens.md`, design ground truth
  `docs/design/tie.dc.html`) on both results screens — the acceptance script for the
  feature, one behaviour per test: the takeover replaces the panel for exactly one
  state, tapping a tied row selects it provisionally, **Let the app break the tie**
  runs a visible server-driven shuffle onto a server-chosen row the organizer can
  still override, **Lock in** writes the resolution and flips an organizer tab *and*
  a guest tab to the ordinary winner ending live over PubSub — whose card and
  paste-to-chat summary name the tie-break and who made it — guests get the waiting
  variant with no tap affordance and no buttons, and every refusal is a flash, never
  a crash.

  The spin's clock is shortened in `config/test.exs`
  (`endgame_tie_spin_interval_ms` / `endgame_tie_spin_ticks`) so the tests that watch
  it land don't sleep through the design's real 1.9 seconds.
  """

  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Group
  alias Consensus.Repo
  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  setup :register_and_log_in_user

  # Long enough for the test-config spin (`config/test.exs`: 4 ticks × 25ms = 100ms)
  # to land, with slack. The mid-spin tests rely on the same clock being *slow enough*
  # that a few synchronous clicks fit inside it.
  @spin_wait 400

  # A completed two-way dead heat: three named options, one ballot approving the first
  # two — both finish level on 1, the third survives at 0. Names are set at creation
  # because the pool freezes on publish (invariant 16). Returns the tied pair in tally
  # (position) order, plus the ballot-casting participant — the natural guest for the
  # `/join` half of these tests.
  defp tied_group(scope, opts \\ []) do
    names = Keyword.get(opts, :names, ["Alpha", "Beta", "Gamma"])
    group = group_fixture(scope, %{deadline_at: future_deadline()})
    activities = for name <- names, do: activity_fixture(group, %{name: name})
    {:ok, group} = Activities.publish_group(scope, group)

    [a, b | _rest] = activities
    participant = participant_fixture(group)
    {:ok, participant} = Voting.cast_ballot(participant, [a.id, b.id])
    {:ok, group} = Activities.complete_group(scope, group)
    {group, {a, b}, activities, participant}
  end

  defp guest_conn do
    Phoenix.ConnTest.build_conn()
  end

  defp guest_conn(group, participant) do
    guest_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)
  end

  # Resolves the group straight in the database — no broadcast — which is exactly the
  # stale window a real second tab sits in between a commit and its PubSub delivery.
  defp resolve_behind_the_tab!(group, activity, resolution) do
    {:ok, _} =
      Repo.get!(Group, group.id)
      |> Group.resolution_changeset(%{
        resolution: resolution,
        resolved_activity_id: activity.id,
        resolved_at: DateTime.utc_now(:second)
      })
      |> Repo.update()
  end

  describe "the organizer's takeover" do
    test "replaces the whole results panel: scene, chips, list, disabled-look primary, violet context",
         %{conn: conn, scope: scope} do
      {group, {a, b}, _activities, _participant} =
        tied_group(scope, names: ["Uchi Sushi", "Cook Butter Tofu", "Third Wheel"])

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      # The headline block, stage 0 subline verbatim (the design's own copy).
      assert html =~ "dead heat"
      assert html =~ "Voting is closed and two options finished on the same score."
      assert html =~ "Only you can break it."

      # The hero: the buzzing counter, the label chip, and the scene's parts actually
      # on their animation classes.
      assert has_element?(lv, "#endgame-tie-hero")
      assert html =~ "TIED 2-WAY"
      assert has_element?(lv, "#endgame-tie-hero span", "NOBODY'S WINNING")
      assert has_element?(lv, "#endgame-tie-hero .endgame-buzz")
      assert html =~ "endgame-tie-bg"
      assert html =~ "endgame-tug"
      assert html =~ "endgame-strain-left"
      assert html =~ "endgame-strain-right"
      assert html =~ "endgame-pulseline"
      assert html =~ "endgame-drip"
      assert html =~ "endgame-rope"

      # TIED FOR FIRST: the state chip reads TAP ONE, both tied rows render as tap
      # targets with their counts in violet mono, the third option is not in the list,
      # and the status line says nothing is selected.
      assert html =~ "TIED FOR FIRST"
      assert has_element?(lv, "#endgame-tie-state", "TAP ONE")
      assert has_element?(lv, "button#endgame-tie-row-#{a.id}", "Uchi Sushi")
      assert has_element?(lv, "button#endgame-tie-row-#{b.id}", "Cook Butter Tofu")
      refute html =~ "Third Wheel"
      assert html =~ "1 VOTE"
      assert has_element?(lv, "#endgame-tie-status", "Nothing selected yet")

      # The action stack: the disabled-look primary (the design's beige, not tangerine,
      # and no press), the secondary, the inert mono caption, and the page's own URL.
      assert has_element?(lv, "#endgame-lock.endgame-lock-idle", "Pick a winner above")
      refute has_element?(lv, "#endgame-lock.bg-tangerine")
      assert has_element?(lv, "#endgame-app-pick", "Let the app break the tie")
      assert html =~ "or run a second round with just these two"
      assert html =~ "/groups/#{group.id}/results"

      # The header context slot names the state, in the design's violet.
      assert has_element?(lv, "#chrome-context.text-violet", "DEAD HEAT")

      # And the ordinary results panel is gone whole: no violet band, no avatar row,
      # no tally, no completed-footer, no old tie card.
      refute html =~ "Voting closed"
      refute html =~ "Final tally"
      refute html =~ "Start another session"
      refute html =~ "Tied at the top"
      refute html =~ "copy-summary"
    end

    test "tapping a tied row selects it: violet ✓ dot, tangerine Lock in <name>, subline switches",
         %{conn: conn, scope: scope} do
      {group, {a, b}, _activities, _participant} =
        tied_group(scope, names: ["Alpha", "Beta", "Gamma"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      html = lv |> element("#endgame-tie-row-#{a.id}") |> render_click()

      # The tapped row is highlighted with the filled violet ✓ dot; the other is not.
      assert has_element?(lv, "#endgame-tie-row-#{a.id}.endgame-tie-row-active")
      assert has_element?(lv, "#endgame-tie-row-#{a.id} span.bg-violet", "✓")
      refute has_element?(lv, "#endgame-tie-row-#{b.id}.endgame-tie-row-active")

      # The primary flips from the disabled look to the tangerine lock naming the pick.
      assert has_element?(lv, "#endgame-lock.bg-tangerine", "Lock in Alpha")
      refute has_element?(lv, "#endgame-lock.endgame-lock-idle")

      # The subline and status line follow, the chip stays TAP ONE (nothing app-picked).
      assert html =~ "Locking it in updates the results page for everyone who voted."
      assert has_element?(lv, "#endgame-tie-status", "Selected: Alpha")
      assert has_element?(lv, "#endgame-tie-state", "TAP ONE")

      # Tapping the other row moves the selection — still provisional, nothing written.
      lv |> element("#endgame-tie-row-#{b.id}") |> render_click()
      assert has_element?(lv, "#endgame-lock.bg-tangerine", "Lock in Beta")
      refute has_element?(lv, "#endgame-tie-row-#{a.id}.endgame-tie-row-active")
      assert is_nil(Activities.get_group!(scope, group.id).resolution)
    end

    test "Lock in flips an open organizer tab AND an open guest tab to the winner ending naming the organizer's tie-break",
         %{conn: conn, scope: scope, user: user} do
      {group, {a, _b}, _activities, guest} = tied_group(scope, names: ["Alpha", "Beta", "Gamma"])

      {:ok, org_lv, _html} = live(conn, ~p"/groups/#{group}/results")

      {:ok, guest_lv, guest_html} =
        live(guest_conn(group, guest), ~p"/join/#{group.slug}/results")

      # Both tabs sit on the takeover before the lock.
      assert render(org_lv) =~ "TIED FOR FIRST"
      assert guest_html =~ "TIED FOR FIRST"

      org_lv |> element("#endgame-tie-row-#{a.id}") |> render_click()
      org_lv |> element("#endgame-lock") |> render_click()

      resolved = Activities.get_group!(scope, group.id)
      assert resolved.resolution == "organizer_pick"
      assert resolved.resolved_activity_id == a.id

      # The organizer's tab: the ordinary winner ending, the tie named and its breaker
      # named — by username, not "The organizer": the guest waiting copy already names
      # the human, and the exit artifact must be at least as specific — plus a flash
      # saying what just locked.
      org_html = render(org_lv)
      assert org_html =~ "We have a winner"
      assert org_html =~ ~s(id="winner-tie-note")
      assert org_html =~ "2 options finished level on 1 approval"
      assert org_html =~ "#{user.username} picked Alpha to break the tie"
      refute org_html =~ "The organizer picked"
      refute org_html =~ "first in the pool"
      assert org_html =~ "Locked in Alpha"
      refute org_html =~ "TIED FOR FIRST"

      # The paste-to-chat summary carries the tie and its breaker out of the app.
      assert has_element?(org_lv, ~s(#copy-summary[data-copy*="ended in a tie at 1"]))

      assert has_element?(
               org_lv,
               ~s(#copy-summary[data-copy*="#{user.username} picked Alpha to break the tie."])
             )

      # The guest's tab flipped over PubSub — no navigation, no reload — to the same
      # winner ending with the same honest note naming the same human.
      guest_html = render(guest_lv)
      assert guest_html =~ "We have a winner"
      assert guest_html =~ "#{user.username} picked Alpha to break the tie"
      refute guest_html =~ "TIED FOR FIRST"
    end
  end

  describe "Let the app break the tie" do
    test "spins visibly, lands on a server-chosen tied row, and stays provisional until locked",
         %{conn: conn, scope: scope} do
      {group, {a, b}, _activities, _participant} =
        tied_group(scope, names: ["Alpha", "Beta", "Gamma"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      # The press itself renders the shuffle state: chip DECIDING…, the status line
      # shuffling, the secondary disabled-in-words, the base subline back.
      html = lv |> element("#endgame-app-pick") |> render_click()
      assert html =~ "DECIDING…"
      assert html =~ "Shuffling the tied options…"
      assert html =~ "Deciding…"
      assert html =~ "Pick a winner above"

      # …then the spin lands: chip APP PICKED, one of the tied rows selected, the
      # subline offering the override, the lock naming the pick.
      Process.sleep(@spin_wait)
      html = render(lv)
      assert has_element?(lv, "#endgame-tie-state", "APP PICKED")
      assert html =~ "The app broke the tie. Lock it in, or override it"

      picked =
        Enum.find([a, b], fn activity ->
          has_element?(lv, "#endgame-tie-row-#{activity.id}.endgame-tie-row-active")
        end)

      assert picked, "the spin landed on neither tied row"
      assert has_element?(lv, "#endgame-lock.bg-tangerine", "Lock in #{picked.name}")
      assert has_element?(lv, "#endgame-tie-status", "Selected: #{picked.name}")

      # Provisional: nothing has been written yet.
      assert is_nil(Activities.get_group!(scope, group.id).resolution)

      # Locking now records it as the app's pick, and the ending says so — card and
      # paste-to-chat string both.
      lv |> element("#endgame-lock") |> render_click()

      resolved = Activities.get_group!(scope, group.id)
      assert resolved.resolution == "app_pick"
      assert resolved.resolved_activity_id == picked.id

      html = render(lv)
      assert html =~ "We have a winner"
      assert html =~ "The app picked #{picked.name} at random to break the tie"

      assert has_element?(
               lv,
               ~s(#copy-summary[data-copy*="The app picked #{picked.name} at random to break the tie."])
             )
    end

    test "the organizer can override the app's pick by tapping the other row — the lock then records organizer_pick",
         %{conn: conn, scope: scope, user: user} do
      {group, {a, b}, _activities, _participant} =
        tied_group(scope, names: ["Alpha", "Beta", "Gamma"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      lv |> element("#endgame-app-pick") |> render_click()
      Process.sleep(@spin_wait)
      render(lv)

      picked =
        Enum.find([a, b], fn activity ->
          has_element?(lv, "#endgame-tie-row-#{activity.id}.endgame-tie-row-active")
        end)

      other = Enum.find([a, b], &(&1.id != picked.id))

      # The override: the chip drops APP PICKED, the subline goes back to the tapped
      # wording, the lock names the override.
      html = lv |> element("#endgame-tie-row-#{other.id}") |> render_click()
      assert has_element?(lv, "#endgame-tie-state", "TAP ONE")
      assert html =~ "Locking it in updates the results page for everyone who voted."
      assert has_element?(lv, "#endgame-lock.bg-tangerine", "Lock in #{other.name}")

      lv |> element("#endgame-lock") |> render_click()

      resolved = Activities.get_group!(scope, group.id)
      assert resolved.resolution == "organizer_pick"
      assert resolved.resolved_activity_id == other.id
      assert render(lv) =~ "#{user.username} picked #{other.name} to break the tie"
    end

    test "a tapped row and the lock are refused mid-spin, and a second spin press is dropped",
         %{conn: conn, scope: scope} do
      {group, {a, _b}, _activities, _participant} = tied_group(scope)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      lv |> element("#endgame-app-pick") |> render_click()

      # Mid-spin: taps and locks are ignored (the design's `if spinning return`), a
      # second press does not restart the clock into a broken state.
      lv |> element("#endgame-tie-row-#{a.id}") |> render_click()
      lv |> element("#endgame-lock") |> render_click()
      lv |> element("#endgame-app-pick") |> render_click()
      assert is_nil(Activities.get_group!(scope, group.id).resolution)

      # The spin still lands cleanly.
      Process.sleep(@spin_wait)
      assert has_element?(lv, "#endgame-tie-state", "APP PICKED")
    end
  end

  describe "refusals" do
    test "locking twice is refused with an error tuple at the context and a flash at the screen",
         %{conn: conn, scope: scope} do
      {group, {a, b}, _activities, _participant} = tied_group(scope)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      lv |> element("#endgame-tie-row-#{a.id}") |> render_click()
      lv |> element("#endgame-lock") |> render_click()

      # The context half: a second resolve refuses with a tuple.
      assert {:error, :already_resolved} =
               Activities.resolve_group(
                 scope,
                 Activities.get_group!(scope, group.id),
                 b.id,
                 "organizer_pick"
               )

      # And the web half never crashes: a mount after the fact renders the winner
      # ending, takeover gone.
      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "We have a winner"
      refute html =~ "endgame-lock"
    end

    test "a stale tab locking after another tab already settled it gets an honest flash, not a crash",
         %{conn: conn, scope: scope, user: user} do
      {group, {a, b}, _activities, _participant} =
        tied_group(scope, names: ["Alpha", "Beta", "Gamma"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      # This tab selects Beta…
      lv |> element("#endgame-tie-row-#{b.id}") |> render_click()

      # …while another tab locks Alpha, unseen by this one.
      resolve_behind_the_tab!(group, a, "organizer_pick")

      # The stale lock refuses in the context, flashes, and the refresh flips this tab
      # to the ending it missed — the FIRST tab's pick, not this one's.
      lv |> element("#endgame-lock") |> render_click()

      html = render(lv)
      assert html =~ "Someone already settled this session"
      assert html =~ "We have a winner"
      assert html =~ "#{user.username} picked Alpha to break the tie"
      refute html =~ "TIED FOR FIRST"
      assert Activities.get_group!(scope, group.id).resolved_activity_id == a.id
    end

    test "a crafted select naming an activity outside the tied set is refused",
         %{conn: conn, scope: scope} do
      {group, {a, _b}, activities, _participant} = tied_group(scope)
      loser = List.last(activities)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      # The un-tied survivor renders no row at all — craft the event by overriding a
      # real row's phx-value-id with its id.
      refute has_element?(lv, "#endgame-tie-row-#{loser.id}")
      lv |> element("#endgame-tie-row-#{a.id}") |> render_click(%{"id" => to_string(loser.id)})

      # Nothing selected: the primary stays the disabled look, and nothing can lock.
      assert has_element?(lv, "#endgame-lock.endgame-lock-idle", "Pick a winner above")
      lv |> element("#endgame-lock") |> render_click()
      assert is_nil(Activities.get_group!(scope, group.id).resolution)

      # Garbage ids are dropped the same way.
      lv |> element("#endgame-tie-row-#{a.id}") |> render_click(%{"id" => "not-a-number"})
      assert has_element?(lv, "#endgame-lock.endgame-lock-idle")

      # And the context itself refuses the same activity on a fresh read — the guard
      # the UI cannot be talked out of.
      assert {:error, :not_a_candidate} =
               Activities.resolve_group(
                 scope,
                 Activities.get_group!(scope, group.id),
                 loser.id,
                 "organizer_pick"
               )
    end
  end

  describe "the guest's takeover" do
    test "gets the scene and the list with no tap affordance, a waiting line naming the organizer, and the standing exit",
         %{conn: _conn, scope: scope, user: user} do
      {group, {a, b}, _activities, guest} =
        tied_group(scope, names: ["Uchi Sushi", "Cook Butter Tofu", "Third Wheel"])

      {:ok, lv, html} = live(guest_conn(group, guest), ~p"/join/#{group.slug}/results")

      # Same scene, same chips, same headline — and the subline names the organizer,
      # not "you".
      assert has_element?(lv, "#endgame-tie-hero")
      assert html =~ "TIED 2-WAY"
      assert html =~ "dead heat"
      assert html =~ "Only #{user.username} can break it."
      refute html =~ "Only you can break it."

      # The same list — but no buttons, no dots, no state chip, no status line.
      assert html =~ "TIED FOR FIRST"
      assert has_element?(lv, "#endgame-tie-row-#{a.id}", "Uchi Sushi")
      assert has_element?(lv, "#endgame-tie-row-#{b.id}", "Cook Butter Tofu")
      refute has_element?(lv, "button#endgame-tie-row-#{a.id}")
      refute has_element?(lv, "#endgame-tie-state")
      refute has_element?(lv, "#endgame-tie-status")
      refute html =~ "TAP ONE"

      # No organizer exits; the waiting line names the organizer; the standing exit
      # survives the takeover.
      refute has_element?(lv, "#endgame-lock")
      refute has_element?(lv, "#endgame-app-pick")
      refute html =~ "Let the app break the tie"
      assert has_element?(lv, "#endgame-waiting", user.username)
      assert has_element?(lv, "#endgame-waiting", "can break this tie")
      assert html =~ "This page flips on its own the moment they do."
      assert has_element?(lv, "#results-start-your-own", "Create your own")

      # The header context names the state in violet here too.
      assert has_element?(lv, "#chrome-context.text-violet", "DEAD HEAT")

      # And the footer table's cells are gone with the panel they belong to.
      refute html =~ "Final tally"
      refute html =~ "results-closed-voted"
    end

    test "a stranger with no token gets the same takeover", %{scope: scope} do
      {group, _tied, _activities, _participant} = tied_group(scope)

      {:ok, _lv, html} = live(guest_conn(), ~p"/join/#{group.slug}/results")

      assert html =~ "dead heat"
      assert html =~ "TIED FOR FIRST"
      refute html =~ "endgame-lock"
    end

    test "forged organizer events from a guest socket write nothing", %{scope: scope} do
      {group, {a, _b}, _activities, guest} = tied_group(scope)

      {:ok, lv, _html} = live(guest_conn(group, guest), ~p"/join/#{group.slug}/results")

      # The controls don't render for a guest, but a socket can push any event it
      # likes at the component; the ignore clauses drop them all.
      lv |> with_target("#endgame-tie") |> render_click("select", %{"id" => to_string(a.id)})
      lv |> with_target("#endgame-tie") |> render_click("app_pick", %{})
      lv |> with_target("#endgame-tie") |> render_click("lock", %{})

      reloaded = Activities.get_group!(scope, group.id)
      assert reloaded.status == :completed
      assert is_nil(reloaded.resolution)
    end
  end

  describe "a three-way tie" do
    test "renders TIED 3-WAY, three rows, and an honest caption", %{conn: conn, scope: scope} do
      {group, activities} = voting_group_fixture(scope, 3)
      participant = participant_fixture(group)
      {:ok, _} = Voting.cast_ballot(participant, Enum.map(activities, & &1.id))
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "TIED 3-WAY"
      assert html =~ "three options finished on the same score"

      for activity <- activities do
        assert has_element?(lv, "button#endgame-tie-row-#{activity.id}")
      end

      # The caption counts what is actually tied — the design's sample data says
      # "these two" because its sample tie is two-way.
      assert html =~ "or run a second round with just these three"

      # And any of the three can be selected and locked.
      third = Enum.at(activities, 2)
      lv |> element("#endgame-tie-row-#{third.id}") |> render_click()
      lv |> element("#endgame-lock") |> render_click()
      assert Activities.get_group!(scope, group.id).resolved_activity_id == third.id
    end
  end

  describe "when the takeover does and does not render" do
    test "a mid-vote dead heat keeps the running tally — the deadline can still break it",
         %{conn: conn, scope: scope} do
      {group, [a, b | _rest]} = voting_group_fixture(scope, 3)
      participant = participant_fixture(group)
      {:ok, _} = Voting.cast_ballot(participant, [a.id, b.id])

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      refute html =~ "TIED FOR FIRST"
      refute html =~ "dead heat"
      assert html =~ "Running tally"
      assert html =~ "TIED FOR THE LEAD"
    end

    test "a resolved tie renders the ordinary winner ending, not the takeover",
         %{conn: conn, scope: scope} do
      {group, {a, _b}, _activities, _participant} = tied_group(scope)

      {:ok, _} =
        Activities.resolve_group(
          scope,
          Activities.get_group!(scope, group.id),
          a.id,
          "organizer_pick"
        )

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      refute html =~ "TIED FOR FIRST"
      assert html =~ "We have a winner"
      assert html =~ "to break the tie"
    end
  end
end
