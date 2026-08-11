defmodule ConsensusWeb.Endgame.AllVetoedTest do
  @moduledoc """
  The All Vetoed takeover (`docs/plans/endgame-screens.md`, design ground truth
  `docs/design/all-vetoed.dc.html`) on both results screens — the acceptance script for
  the feature, one behaviour per test: the takeover replaces the panel for exactly one
  state, the poke toy cycles the design's four stages verbatim and wraps, the carnage
  list shows veto counts and never names (D-035), **Let the app pick one at random**
  flips an organizer tab *and* a guest tab to the ordinary winner ending live over
  PubSub, **Add new options** reopens the pool for a round 2 that runs on the same
  share link with the same participant tokens, guests get the waiting variant with no
  organizer exits, and every refusal is a flash, never a crash.
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

  # A published group whose options carry the given names — the takeover's carnage list
  # renders names, so the tests that read it want ones they chose.
  defp published_group(scope, names) do
    group = group_fixture(scope, %{deadline_at: future_deadline()})
    activities = for name <- names, do: activity_fixture(group, %{name: name})
    {:ok, group} = Activities.publish_group(scope, group)
    {group, activities}
  end

  # One participant per option, each vetoing that option — the all-vetoed endgame.
  # `display_names` (optional) names the participants, so a test can assert the carnage
  # list never leaks them (D-035).
  defp veto_all(group, activities, display_names \\ []) do
    activities
    |> Enum.with_index()
    |> Enum.map(fn {activity, index} ->
      attrs =
        case Enum.at(display_names, index) do
          nil -> %{}
          name -> %{display_name: name}
        end

      participant = participant_fixture(group, attrs)
      {:ok, participant} = Voting.cast_ballot(participant, [], activity.id)
      participant
    end)
  end

  defp all_vetoed_group(scope, names, display_names \\ []) do
    {group, activities} = published_group(scope, names)
    participants = veto_all(group, activities, display_names)
    {:ok, group} = Activities.complete_group(scope, group)
    {group, activities, participants}
  end

  defp guest_conn do
    Phoenix.ConnTest.build_conn()
  end

  defp guest_conn(group, participant) do
    guest_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)
  end

  describe "the organizer's takeover" do
    test "replaces the whole results panel: scene, stages, carnage counts, both exits, tangerine context",
         %{conn: conn, scope: scope} do
      {group, _activities, _participants} =
        all_vetoed_group(scope, ["Ember & Rye", "Little Saigon"], ["Maya", "Dev"])

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      # Stage 0, verbatim from the design source.
      assert html =~ "Nobody wanted anything."
      assert html =~ "Every single option got vetoed. That is genuinely hard to do."

      # The hero: the poke button, the buzzing counter (pool size = 2), the label chip,
      # and the scene's keyframes actually attached to its parts.
      assert has_element?(lv, "button#endgame-hero")
      assert html =~ "VETOES 2/2"
      assert html =~ "TAP THE GUY"
      assert has_element?(lv, "#endgame-hero .endgame-buzz")
      assert html =~ "endgame-fire-bg"
      assert html =~ "endgame-bob"
      assert html =~ "animation:flick 1.05s ease-in-out infinite"
      assert html =~ "animation:ember 2.6s linear infinite"

      # THE CARNAGE: every option struck through, with veto COUNTS in the mono slot —
      # never a participant's name (D-035; the design's sample data says MAYA/DEV and
      # that deviation is deliberate).
      assert html =~ "THE CARNAGE"
      assert has_element?(lv, "#endgame-carnage .line-through", "Ember & Rye")
      assert has_element?(lv, "#endgame-carnage .line-through", "Little Saigon")
      assert html =~ "1 VETO"
      refute html =~ "Maya"
      refute html =~ "MAYA"
      refute html =~ "Dev"

      # Both organizer exits and the design's caption line.
      assert has_element?(lv, "#endgame-add-options", "Add new options")
      assert has_element?(lv, "#endgame-rescue", "Let the app pick one at random")
      assert html =~ "or accept that pizza was always the answer"

      # The header context slot names the state, in the design's tangerine.
      assert has_element?(lv, "#chrome-context.text-tangerine", "ALL VETOED")

      # And the ordinary results panel is gone whole: no violet band, no avatar row,
      # no tally, no completed-footer.
      refute html =~ "Voting closed"
      refute html =~ "WHO&#39;S VOTED"
      refute html =~ "Final tally"
      refute html =~ "Start another session"
    end

    test "a veto count above one pluralizes", %{conn: conn, scope: scope} do
      {group, [a, b]} = published_group(scope, ["Alpha", "Beta"])
      veto_all(group, [a, b])
      # A third participant piles a second veto on Alpha.
      extra = participant_fixture(group)
      {:ok, _} = Voting.cast_ballot(extra, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "2 VETOES"
      assert html =~ "1 VETO"
      # Comic counter counts the pool, not the vetoes: 2 options, 0 pokes.
      assert html =~ "VETOES 2/2"
    end

    test "poking five times cycles the four stages verbatim, wraps, and moves the counter",
         %{conn: conn, scope: scope} do
      {group, _activities, _participants} = all_vetoed_group(scope, ["A", "B", "C"])

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")
      poke = fn -> lv |> element("#endgame-hero") |> render_click() end

      assert html =~ "Nobody wanted anything."
      assert html =~ "VETOES 3/3"

      html = poke.()
      assert html =~ "Still nothing."

      assert html =~
               "The group has now rejected more restaurants than most people visit in a year."

      assert html =~ "VETOES 4/4"

      html = poke.()
      assert html =~ "This is fine."
      assert html =~ "It is not fine. Somebody has to pick a place eventually."
      assert html =~ "VETOES 5/5"

      html = poke.()
      assert html =~ "Total anarchy achieved."
      assert html =~ "Congratulations. You have unlocked the worst possible outcome."
      assert html =~ "VETOES 6/6"

      # The fourth poke wraps to stage 0, counter and all — the design's `% 4`.
      html = poke.()
      assert html =~ "Nobody wanted anything."
      assert html =~ "VETOES 3/3"

      # And a fifth keeps cycling.
      html = poke.()
      assert html =~ "Still nothing."
      assert html =~ "VETOES 4/4"
    end
  end

  describe "Let the app pick one at random" do
    test "flips an open organizer tab AND an open guest tab to the winner ending live",
         %{conn: conn, scope: scope} do
      {group, _activities, [p1 | _rest]} =
        all_vetoed_group(scope, ["Osteria Mozza", "Pizza Corner", "Noodle Bar"])

      {:ok, org_lv, _html} = live(conn, ~p"/groups/#{group}/results")
      {:ok, guest_lv, guest_html} = live(guest_conn(group, p1), ~p"/join/#{group.slug}/results")

      # Both tabs are sitting on the takeover before the pick.
      assert render(org_lv) =~ "THE CARNAGE"
      assert guest_html =~ "THE CARNAGE"

      org_lv |> element("#endgame-rescue") |> render_click()

      resolved = Activities.get_group!(scope, group.id)
      assert resolved.resolution == "app_rescue"
      rescued = Enum.find(resolved.activities, &(&1.id == resolved.resolved_activity_id))

      # The organizer's tab: the ordinary winner ending, naming the rescued option with
      # the honest app-picked line, plus a flash naming the pick.
      org_html = render(org_lv)
      assert org_html =~ "We have a winner"
      assert org_html =~ ~s(id="winner-rescue-note")
      assert org_html =~ "the app picked #{rescued.name} at random"
      assert org_html =~ "The app picked #{rescued.name} at random"
      assert org_html =~ "final result"
      refute org_html =~ "THE CARNAGE"

      # The guest's tab flipped over PubSub — no navigation, no reload.
      guest_html = render(guest_lv)
      assert guest_html =~ "We have a winner"
      assert guest_html =~ ~s(id="winner-rescue-note")
      refute guest_html =~ "THE CARNAGE"

      # The rescued row is un-struck in the final tally; the other two stay struck.
      refute has_element?(org_lv, ".line-through", rescued.name)

      for other <- resolved.activities, other.id != rescued.id do
        assert has_element?(org_lv, ".line-through", other.name)
      end

      # The paste-to-chat summary is honest too — chance, not approval.
      assert org_html =~ "so the app picked"
    end

    test "a stale tab pressing rescue after another tab already settled it gets an honest flash, not a crash",
         %{conn: conn, scope: scope} do
      {group, [a | _rest], _participants} = all_vetoed_group(scope, ["A", "B"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      # Another tab resolves the group. Written straight to the database — no broadcast —
      # which is exactly the stale window a real second tab sits in between the commit
      # and its PubSub delivery.
      {:ok, _} =
        Repo.get!(Group, group.id)
        |> Group.resolution_changeset(%{
          resolution: "app_rescue",
          resolved_activity_id: a.id,
          resolved_at: DateTime.utc_now(:second)
        })
        |> Repo.update()

      # The stale tab still shows the takeover and presses the button.
      lv |> element("#endgame-rescue") |> render_click()

      html = render(lv)
      # The context refused with a tuple, the component flashed it, and the refresh
      # flipped this tab to the result it missed.
      assert html =~ "Someone already settled this session"
      assert html =~ "We have a winner"
      refute html =~ "THE CARNAGE"

      # And nothing double-resolved: the first tab's pick stands.
      assert Activities.get_group!(scope, group.id).resolved_activity_id == a.id
    end

    test "rescuing twice is refused with an error tuple at the context and a flash at the screen",
         %{conn: conn, scope: scope} do
      {group, _activities, _participants} = all_vetoed_group(scope, ["A", "B"])

      {:ok, _resolved} = Activities.rescue_group(scope, Activities.get_group!(scope, group.id))

      # The second rescue refuses with a tuple — the context half.
      assert {:error, :already_resolved} =
               Activities.rescue_group(scope, Activities.get_group!(scope, group.id))

      # And the web half never crashes: a mount after the fact renders the winner
      # ending, takeover gone.
      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "We have a winner"
      refute html =~ "endgame-rescue"
    end
  end

  describe "Add new options — round 2 on the same share link" do
    test "reopens the pool, requires a fresh deadline, and a round-1 guest re-votes on the old token",
         %{conn: conn, scope: scope} do
      {group, _activities} = published_group(scope, ["Osteria Mozza", "Noodle Bar"])
      [p1 | _] = veto_all(group, Activities.get_group!(scope, group.id).activities, ["Priya"])
      {:ok, group} = Activities.complete_group(scope, group)

      # The guest's browser from round 1: the session token minted when Priya joined.
      round1_guest = guest_conn(group, p1)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")
      lv |> element("#endgame-add-options") |> render_click()

      # Lands on the options screen (no bounce to review — the pool is a draft again),
      # with a flash saying the pool is open and a new deadline is needed.
      flash = assert_redirect(lv, ~p"/groups/#{group}/options")
      assert flash["info"] =~ "pool is open again"
      assert flash["info"] =~ "new deadline"

      {:ok, options_lv, _html} = live(conn, ~p"/groups/#{group}/options")

      options_lv
      |> form("#add-option-form", add_option: %{"query" => "Pizza Corner"})
      |> render_submit()

      reopened = Activities.get_group!(scope, group.id)
      assert reopened.status == :draft
      assert is_nil(reopened.deadline_at)
      assert "Pizza Corner" in Enum.map(reopened.activities, & &1.name)

      # The deadline is set on /groups/:id/edit, exactly as the flash said.
      {:ok, edit_lv, _html} = live(conn, ~p"/groups/#{group}/edit")

      edit_lv
      |> element(~s{button[phx-click="select_deadline"]}, "Tomorrow 5pm")
      |> render_click()

      edit_lv |> form("#group-form", group: %{"title" => reopened.title}) |> render_submit()
      assert_redirect(edit_lv, ~p"/groups/#{group}/options")

      # Publish round 2 from review.
      {:ok, review_lv, _html} = live(conn, ~p"/groups/#{group}/review")
      review_lv |> element(~s{[phx-click="publish"]}) |> render_click()
      assert_redirect(review_lv, ~p"/groups/#{group}/share")

      republished = Activities.get_group!(scope, group.id)
      assert republished.status == :voting
      # The same share link — the slug never changed.
      assert republished.slug == group.slug

      # Priya opens the SAME link in the SAME browser: the old token resolves, no name
      # is re-entered, and the ballot is castable again (voted_at was reset).
      {:ok, ballot_lv, ballot_html} = live(round1_guest, ~p"/join/#{group.slug}/vote")
      assert ballot_html =~ "Pizza Corner"

      new_option = Enum.find(republished.activities, &(&1.name == "Pizza Corner"))

      ballot_lv
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{new_option.id}']")
      |> render_click()

      ballot_lv |> element("#submit-ballot") |> render_click()
      assert_redirect(ballot_lv, ~p"/join/#{group.slug}/results")

      # Round 2 closes on the ordinary winner ending — no takeover, no rescue language.
      {:ok, _} = Activities.complete_group(scope, Activities.get_group!(scope, group.id))

      {:ok, _results_lv, html} = live(round1_guest, ~p"/join/#{group.slug}/results")
      assert html =~ "We have a winner"
      assert html =~ "Pizza Corner"
      refute html =~ "Nobody wanted anything."
      refute html =~ "at random"
    end

    test "pressing an exit after another tab already rescued gets an honest flash and deletes nothing",
         %{conn: conn, scope: scope} do
      {group, [a | _rest], _participants} = all_vetoed_group(scope, ["A", "B"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      # Another tab rescued it — straight to the database, no broadcast (the stale
      # window between a commit and its PubSub delivery).
      {:ok, _} =
        Repo.get!(Group, group.id)
        |> Group.resolution_changeset(%{
          resolution: "app_rescue",
          resolved_activity_id: a.id,
          resolved_at: DateTime.utc_now(:second)
        })
        |> Repo.update()

      # The stale tab presses "Add new options": `reopen_group/2` re-reads, refuses with
      # `:already_resolved`, and — crucially — deletes no vote rows: the declared result
      # stands, and this tab flips to it.
      lv |> element("#endgame-add-options") |> render_click()

      html = render(lv)
      assert html =~ "Someone already settled this session"
      assert html =~ "We have a winner"

      reloaded = Activities.get_group!(scope, group.id)
      assert reloaded.status == :completed
      assert reloaded.resolution == "app_rescue"
    end

    test "a stale tab whose group went back to draft is refused and follows it to the wizard",
         %{conn: conn, scope: scope} do
      {group, _activities, _participants} = all_vetoed_group(scope, ["A", "B"])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      # Another tab reopened it — simulated without the broadcast, so this tab is stale.
      force_group!(group, %{status: :draft, completed_at: nil})

      # The press refuses in the context (`:not_completed`), and the `:endgame_refresh`
      # reload finds a draft and follows it to the review screen instead of crashing on
      # a results render no draft can have. (The refusal's error flash renders in the
      # diff before the redirect; the flash that rides the redirect is the reload's own
      # reopened note — LiveView clears a flash once it has been sent.)
      lv |> element("#endgame-rescue") |> render_click()

      flash = assert_redirect(lv, ~p"/groups/#{group}/review")
      assert flash["info"] =~ "reopened"
    end

    test "an organizer tab left open on results follows a reopen to the wizard over PubSub",
         %{conn: conn, scope: scope} do
      {group, _activities, _participants} = all_vetoed_group(scope, ["A", "B"])

      {:ok, watcher, _html} = live(conn, ~p"/groups/#{group}/results")

      {:ok, _} = Activities.reopen_group(scope, Activities.get_group!(scope, group.id))

      flash = assert_redirect(watcher, ~p"/groups/#{group}/review")
      assert flash["info"] =~ "reopened"
    end

    test "a guest tab left open on results is told the pause keeps their link alive",
         %{conn: _conn, scope: scope} do
      {group, _activities, [p1 | _rest]} = all_vetoed_group(scope, ["A", "B"])

      {:ok, guest_lv, _html} = live(guest_conn(group, p1), ~p"/join/#{group.slug}/results")

      {:ok, _} = Activities.reopen_group(scope, Activities.get_group!(scope, group.id))

      flash = assert_redirect(guest_lv, "/")
      assert flash["info"] =~ "Keep your link"
    end
  end

  describe "the guest's takeover" do
    test "gets the scene and carnage, a waiting line naming the organizer, the standing exit — and no organizer buttons",
         %{conn: _conn, scope: scope, user: user} do
      {group, _activities, [p1 | _rest]} =
        all_vetoed_group(scope, ["Ember & Rye", "Little Saigon"])

      {:ok, lv, html} = live(guest_conn(group, p1), ~p"/join/#{group.slug}/results")

      # Same scene, same stages, same carnage.
      assert html =~ "Nobody wanted anything."
      assert html =~ "THE CARNAGE"
      assert html =~ "VETOES 2/2"
      assert has_element?(lv, "button#endgame-hero")

      # The waiting line names the organizer as the one who can fix it.
      assert has_element?(lv, "#endgame-waiting", user.username)
      assert has_element?(lv, "#endgame-waiting", "can fix this")
      assert html =~ "This page flips on its own the moment they do."

      # The standing exit survives the takeover; the organizer's exits never render.
      assert has_element?(lv, "#results-start-your-own", "Create your own")
      refute has_element?(lv, "#endgame-add-options")
      refute has_element?(lv, "#endgame-rescue")

      # The header context names the state in tangerine here too.
      assert has_element?(lv, "#chrome-context.text-tangerine", "ALL VETOED")

      # And the footer table's cells are gone with the panel they belong to.
      refute html =~ "Final tally"
      refute html =~ "results-closed-voted"
    end

    test "a stranger with no token gets the same takeover", %{scope: scope} do
      {group, _activities, _participants} = all_vetoed_group(scope, ["A", "B"])

      {:ok, _lv, html} = live(guest_conn(), ~p"/join/#{group.slug}/results")

      assert html =~ "Nobody wanted anything."
      refute html =~ "endgame-add-options"
    end

    test "the poke toy is the guest's too", %{scope: scope} do
      {group, _activities, [p1 | _rest]} = all_vetoed_group(scope, ["A", "B", "C"])

      {:ok, lv, _html} = live(guest_conn(group, p1), ~p"/join/#{group.slug}/results")

      html = lv |> element("#endgame-hero") |> render_click()
      assert html =~ "Still nothing."
      assert html =~ "VETOES 4/4"
    end

    test "a forged organizer event from a guest socket writes nothing", %{scope: scope} do
      {group, _activities, [p1 | _rest]} = all_vetoed_group(scope, ["A", "B"])

      {:ok, lv, _html} = live(guest_conn(group, p1), ~p"/join/#{group.slug}/results")

      # The buttons don't render for a guest, but a socket can push any event it likes
      # at the component; the ignore clauses drop it on the floor.
      lv |> with_target("#endgame-all-vetoed") |> render_click("app_rescue", %{})
      lv |> with_target("#endgame-all-vetoed") |> render_click("add_options", %{})

      reloaded = Activities.get_group!(scope, group.id)
      assert reloaded.status == :completed
      assert is_nil(reloaded.resolution)
    end
  end

  describe "when the takeover does and does not render" do
    test "a mid-vote all-vetoed pool keeps the running tally — votes can still come in",
         %{conn: conn, scope: scope} do
      {group, activities} = published_group(scope, ["A", "B"])
      veto_all(group, activities)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      refute html =~ "THE CARNAGE"
      assert html =~ "Running tally"
    end

    test "a vetoes-only outcome (a survivor exists) is not a takeover", %{
      conn: conn,
      scope: scope
    } do
      {group, [a, _b]} = published_group(scope, ["A", "B"])
      participant = participant_fixture(group)
      {:ok, _} = Voting.cast_ballot(participant, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      refute html =~ "THE CARNAGE"
      assert html =~ "Votes came in, but nothing survived them"
    end
  end
end
