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

  # Every cell of {voting, completed, cancelled} × {voted, joined-but-not-voted, never
  # joined}. Nine, one per test, because the bug this replaces was a *missing*
  # combination: a `:completed` group in a browser that had never voted matched none of
  # the three old `:if`s and the footer rendered completely empty — an outcome with no
  # exit. A table of nine cannot hide a tenth.
  #
  # `#results-start-your-own` is asserted in all nine: whatever state a visitor arrives
  # in, there must be a labelled way off this screen.
  describe "the footer covers every {status} × {participation} cell" do
    setup do
      scope = user_scope_fixture()
      {group, activities} = voting_group_fixture(scope, 2)
      %{scope: scope, group: group, activities: activities}
    end

    # The label matches the header pill's word for word. They are one offer rendered
    # twice, not two offers — the two strings used to differ ("Start your own vote →" vs
    # "Create your own →") on a screen whose only two controls these are.
    defp assert_has_an_exit(lv, html) do
      assert has_element?(lv, "#results-start-your-own")
      assert html =~ "Create your own"

      # **It has to look like a control, and it has to be on screen.** It was a bare 12.5px
      # violet text link — no border, no fill, no shadow — sitting at document y=1168 in a
      # 900px viewport, on the terminal screen of the flow the product exists for and the
      # one the PRD's "guest drop-off under 5%" is measured on. It is a `<.button>` now, and
      # `.results-actions` (see `assets/css/app.css`) is what keeps the block it sits in
      # pinned to the bottom of the viewport rather than 268px under it.
      assert has_element?(lv, ".results-actions #results-start-your-own")
      assert has_element?(lv, "#results-start-your-own.border-2")
    end

    test "voting × voted", ctx do
      %{group: group, activities: [a, _b]} = ctx
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])

      {:ok, lv, html} =
        live(with_participant(ctx.conn, group, participant), ~p"/join/#{group.slug}/results")

      assert html =~ "Your votes are in."
      assert has_element?(lv, "#results-watching")
      assert html =~ "Nothing more to do"
      # It says the page is live and when it closes — the two things a voter who has
      # just submitted actually wants, and the two the old dead end omitted.
      assert html =~ "moves on its own"
      # `Deadlines.label_for/3` already starts with "Closes", so the copy must not embed
      # it in "Voting closes …" — the first cut read "Voting closes Closes Tomorrow 5:00 PM".
      assert html =~ "Closes "
      refute html =~ "Voting closes Closes"
      # The `else` branch that used to sit here ("there is no deadline on this one") is
      # unreachable: `publish_group/2` refuses a nil deadline, so no group this LiveView
      # can render has one.
      refute html =~ "there is no deadline on this one"
      refute html =~ "Cast your vote"
      refute html =~ "Change my ranking"
      # The organizer's `Close now` is rendered for *every* `:voting` group, so "nobody has
      # to press anything" implied a fixed close time and set a voter up to find the vote
      # over hours early. Keep the true half of what the old nudge line said.
      refute html =~ "nobody has to press anything"
      assert html =~ "can also close it early"
      # While the vote is open the ★ means "ahead right now", and one screen later the
      # identical glyph means "won" inside the green winner card. A voter who has cast the
      # only ballot sees "1/1 voted" and a starred row and reads it as decided.
      assert has_element?(lv, "#tally-star-legend")
      assert html =~ "LEADING RIGHT NOW"
      assert_has_an_exit(lv, html)
    end

    test "voting × joined but not voted", ctx do
      %{group: group} = ctx
      participant = participant_fixture(group)

      {:ok, lv, html} =
        live(with_participant(ctx.conn, group, participant), ~p"/join/#{group.slug}/results")

      assert html =~ "Cast your vote"
      refute html =~ "Your votes are in."
      assert_has_an_exit(lv, html)
    end

    test "voting × never joined (a direct link)", ctx do
      %{group: group} = ctx

      {:ok, lv, html} = live(ctx.conn, ~p"/join/#{group.slug}/results")

      assert html =~ "Cast your vote"
      assert html =~ group.title
      assert_has_an_exit(lv, html)
    end

    test "completed × voted", ctx do
      %{scope: scope, group: group, activities: [a, _b]} = ctx
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} =
        live(with_participant(ctx.conn, group, participant), ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-closed-voted")
      assert html =~ "Voting is closed."
      assert html =~ "your votes are counted in it"
      refute html =~ "Cast your vote"
      assert_has_an_exit(lv, html)
    end

    # Its own cell, not `:closed_missed`. This browser holds a participant token, which
    # can only be minted while the group is `:voting`, and the avatar row above says "you"
    # — so "Voting closed before you got here" was flatly false, and a test pinned it.
    test "completed × joined but not voted", ctx do
      %{scope: scope, group: group} = ctx
      participant = participant_fixture(group)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} =
        live(with_participant(ctx.conn, group, participant), ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-closed-no-ballot")
      assert html =~ "Voting closed before your votes went in."
      assert html =~ "You opened the ballot but never sent it"
      refute html =~ "Voting closed before you got here."
      refute html =~ "Cast your vote"
      # Their own avatar says "you", which outranks everything — see the sibling assertion
      # on the cell below for the non-viewer caption.
      #
      # The ★ legend is a `:voting`-only thing: here the star means "won", not "ahead".
      refute has_element?(lv, "#tally-star-legend")
      assert_has_an_exit(lv, html)
    end

    # A participant who never sent a ballot must not be captioned "waiting" under a header
    # reading **Voting closed**, on the same screen whose footer says there is no way to
    # add a vote to a finished session. Nothing is waiting; they missed it.
    test "completed — a non-voter's avatar says they missed it, not that they are waiting",
         ctx do
      %{scope: scope, group: group} = ctx
      _never_voted = participant_fixture(group)
      {:ok, _group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(ctx.conn, ~p"/join/#{group.slug}/results")

      assert html =~ "missed it"
      refute html =~ ">waiting<"
    end

    # The cell that used to render an entirely empty footer. `:closed_missed` is now this
    # cell alone — a browser with no participant token, which genuinely did arrive late.
    test "completed × never joined", ctx do
      %{scope: scope, group: group} = ctx
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} = live(ctx.conn, ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-closed-missed")
      assert html =~ "Voting closed before you got here."
      refute has_element?(lv, "#results-closed-no-ballot")
      refute has_element?(lv, "#results-closed-just-now")
      assert_has_an_exit(lv, html)
    end

    # The same cell, on the other side of the deadline, for a reader who was already
    # here. Screenshot pair 20 seconds apart on one never-reloaded page: the footer offered
    # "Cast your vote" over "Closes Today 7:03 AM — voting locks then, on its own", the
    # deadline passed, the LiveView flipped in place, and the page then told them voting
    # had closed **before they got here**. `:stranger` is the more common arrival of the
    # two — a guest reading the tally without joining — so this is the cell that mattered
    # most and the one that kept asserting it.
    test "completed × never joined, but this page watched it close", ctx do
      %{scope: scope, group: group} = ctx

      {:ok, lv, html} = live(ctx.conn, ~p"/join/#{group.slug}/results")
      assert html =~ "Cast your vote"

      # Exactly what happens in production: the group completes and the already-mounted
      # LiveView re-renders in place, without a remount.
      {:ok, _group} = Activities.complete_group(scope, group)
      send(lv.pid, {:group_updated, group})
      html = render(lv)

      assert has_element?(lv, "#results-closed-just-now")
      assert html =~ "Voting just closed."
      # `complete_group/2` is the organizer's **Close now** button, and this group's
      # deadline is still in the future — so the sentence must not blame the deadline.
      # `saw_voting?` records only that the group was `:voting` at mount; it says nothing
      # about how it ended, and the first version of this cell asserted "the deadline
      # passed" to a reader whose session had been closed by hand with a day left on the
      # countdown. `GroupLive.Results` already carried a `closed_early?/1` for exactly this
      # and it was not grepped for.
      assert html =~ "closed it while you were on this page"
      refute html =~ "The deadline passed while you were on this page"
      refute html =~ "before you got here"
      refute has_element?(lv, "#results-closed-missed")
      assert_has_an_exit(lv, html)
    end

    test "completed × never joined, watching an expired deadline close it", ctx do
      %{scope: scope, group: group} = ctx

      {:ok, lv, _html} = live(ctx.conn, ~p"/join/#{group.slug}/results")

      # The other half of the same cell: `completed_at` at or after `deadline_at` is what
      # the lazy sweep in `Activities.maybe_complete_group/1` stamps, so this reader really
      # did watch the clock run out.
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _group} =
        group
        |> Ecto.Changeset.change(deadline_at: DateTime.add(group.completed_at, -60, :second))
        |> Consensus.Repo.update()

      send(lv.pid, {:group_updated, group})
      html = render(lv)

      assert has_element?(lv, "#results-closed-just-now")
      assert html =~ "The deadline passed while you were on this page"
      refute html =~ "closed it while you were on this page"
      assert_has_an_exit(lv, html)
    end

    test "cancelled × voted", ctx do
      %{scope: scope, group: group, activities: [a, _b]} = ctx
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.cancel_group(scope, group)

      {:ok, lv, html} =
        live(with_participant(ctx.conn, group, participant), ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-cancelled")
      assert html =~ "This session was cancelled."
      assert_has_an_exit(lv, html)
    end

    test "cancelled × joined but not voted", ctx do
      %{scope: scope, group: group} = ctx
      participant = participant_fixture(group)
      {:ok, group} = Activities.cancel_group(scope, group)

      {:ok, lv, html} =
        live(with_participant(ctx.conn, group, participant), ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-cancelled")
      refute html =~ "Cast your vote"
      assert_has_an_exit(lv, html)
    end

    test "cancelled × never joined", ctx do
      %{scope: scope, group: group} = ctx
      {:ok, group} = Activities.cancel_group(scope, group)

      {:ok, lv, html} = live(ctx.conn, ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-cancelled")
      assert_has_an_exit(lv, html)
    end
  end

  # The two false promises the participant's half of the shared component carried after
  # the organizer's half had been corrected. `grep -rn 'nudge' lib/` finds no nudge path,
  # and `/about` says this app sends no notifications.
  describe "nothing on this screen promises nudging, or ranks anything" do
    test "the avatar caption says WHO'S VOTED, and no cell mentions nudging", %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])

      for status_fun <- [& &1, &complete(scope, &1), &cancel(scope, &1)] do
        group = status_fun.(group)
        conn = with_participant(conn, group, participant)
        {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

        assert html =~ "WHO&#39;S VOTED"
        refute html =~ "ORGANIZER NUDGES"
        refute html =~ "nudge"
        refute html =~ "close early"
        refute html =~ "ranking"
      end
    end

    defp complete(scope, group) do
      {:ok, group} = Activities.complete_group(scope, group)
      group
    end

    defp cancel(scope, group) do
      {:ok, group} = Activities.cancel_group(scope, group)
      group
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
      refute html =~ "We have a winner"
    end

    # `Voting.tally/1` gates only `winner?` on `:completed`; `leader?` survives a
    # cancellation and `Sticker.tally_bar/1` paints its ★ from `leader?`. So this screen
    # rendered a starred front-runner under **Final tally** while saying twice that the
    # session was cancelled and nobody won. `presentable_tally/2` takes the crown off.
    test "paints no leader star — there is no answer on a cancelled session", %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.cancel_group(scope, group)
      conn = with_participant(conn, group, participant)

      {:ok, _lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "Final tally"
      assert html =~ a.name
      refute html =~ "★"
      assert html =~ "cancelled before a winner was chosen"
    end
  end

  # Tangerine appears exactly once per screen, on the one forward action. On this screen
  # that is `Create your own →` in every cell but one: `:can_vote` already spends it on
  # "Cast your vote" directly above, and a guest who has not voted yet must not be offered
  # a louder door out than the ballot.
  describe "#results-start-your-own and the screen's one tangerine" do
    test "is the primary action once there is no ballot left to cast", %{conn: conn} do
      scope = user_scope_fixture()
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [a.id])
      conn = with_participant(conn, group, participant)

      {:ok, lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#results-start-your-own.bg-tangerine")
      refute html =~ "Cast your vote"
    end

    test "steps down to the secondary while the ballot is still the forward action",
         %{conn: conn} do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      conn = with_participant(conn, group, participant)

      {:ok, lv, html} = live(conn, ~p"/join/#{group.slug}/results")

      assert html =~ "Cast your vote"
      refute has_element?(lv, "#results-start-your-own.bg-tangerine")
      assert has_element?(lv, "#results-start-your-own.bg-white")
    end
  end
end
